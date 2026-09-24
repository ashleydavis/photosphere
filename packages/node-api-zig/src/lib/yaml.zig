//
// Stand-in for the third-party `js-yaml` package (load and dump) used by news-fetcher.ts and news-state.ts
// (this file has no TypeScript counterpart). It covers the YAML that the news feed and the news state use:
// block mappings and sequences, flow sequences and mappings of scalars, plain, single-quoted and double-quoted
// scalars with the core schema (null, booleans, numbers), and comments. Block scalars (| and >), anchors,
// aliases, tags and multi-document streams are not supported and report a YAMLException like js-yaml's
// errors for malformed input.
//

const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// A line of the document with its indentation.
//
const Line = struct {
    // The number of leading spaces.
    indent: usize,

    // The text after the indentation, with the comment and trailing spaces removed.
    text: []const u8,

    // The 1-based line number (for error messages).
    number: usize,
};

//
// Throws the error js-yaml throws for malformed input.
//
fn yamlError(message: []const u8, lineNumber: usize) errors.ThrownError {
    errors.recordError("YAMLException", "{s} ({d}:1)", .{ message, lineNumber });
    return error.Thrown;
}

//
// Removes a comment (` #...` or a line starting with #) that is not inside quotes, and trailing spaces.
//
fn stripComment(text: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var index: usize = 0;
    while (index < text.len) {
        const character = text[index];
        if (in_double) {
            if (character == '\\') {
                index += 2;
                continue;
            }
            if (character == '"') {
                in_double = false;
            }
        }
        else if (in_single) {
            if (character == '\'') {
                in_single = false;
            }
        }
        else if (character == '"') {
            in_double = true;
        }
        else if (character == '\'') {
            in_single = true;
        }
        else if (character == '#' and (index == 0 or text[index - 1] == ' ' or text[index - 1] == '\t')) {
            return std.mem.trimEnd(u8, text[0..index], " \t");
        }
        index += 1;
    }
    return std.mem.trimEnd(u8, text, " \t\r");
}

//
// Splits the document into the lines that have content.
//
fn splitLines(allocator: std.mem.Allocator, source: []const u8) ![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var number: usize = 0;
    while (iterator.next()) |raw_line| {
        number += 1;
        var indent: usize = 0;
        while (indent < raw_line.len and raw_line[indent] == ' ') {
            indent += 1;
        }
        const text = stripComment(raw_line[indent..]);
        if (text.len == 0) {
            continue;
        }
        if (std.mem.eql(u8, text, "---") and indent == 0 and lines.items.len == 0) {
            continue;
        }
        if (text[0] == '\t') {
            return yamlError("tab characters must not be used in indentation", number);
        }
        try lines.append(allocator, .{ .indent = indent, .text = text, .number = number });
    }
    return lines.items;
}

//
// The parser state: the lines and the position of the next line.
//
const Parser = struct {
    // Allocates the values.
    allocator: std.mem.Allocator,

    // The lines with content.
    lines: []const Line,

    // The index of the next line.
    position: usize,

    //
    // Parses the block node whose lines are indented at least `minIndent`, starting at the next line.
    //
    fn parseBlock(self: *Parser, minIndent: usize) anyerror!std.json.Value {
        if (self.position >= self.lines.len) {
            return .null;
        }
        const line = self.lines[self.position];
        if (line.indent < minIndent) {
            return .null;
        }
        if (isSequenceEntry(line.text)) {
            return self.parseSequence(line.indent);
        }
        if (findMappingColon(line.text) != null) {
            return self.parseMapping(line.indent, null);
        }
        self.position += 1;
        return parseInlineValue(self.allocator, line.text, line.number);
    }

    //
    // Parses a block sequence whose entries are at `indent`.
    //
    fn parseSequence(self: *Parser, indent: usize) anyerror!std.json.Value {
        var array = std.json.Array.init(self.allocator);
        while (self.position < self.lines.len) {
            const line = self.lines[self.position];
            if (line.indent != indent or !isSequenceEntry(line.text)) {
                if (line.indent > indent) {
                    return yamlError("bad indentation of a sequence entry", line.number);
                }
                break;
            }
            const rest = std.mem.trimStart(u8, line.text[1..], " ");
            if (rest.len == 0) {
                self.position += 1;
                try array.append(try self.parseBlock(indent + 1));
                continue;
            }
            const itemIndent = indent + (line.text.len - rest.len);
            if (isSequenceEntry(rest)) {
                // A nested sequence on the same line ("- - a").
                self.lines = try self.replaceCurrent(itemIndent, rest);
                try array.append(try self.parseSequence(itemIndent));
                continue;
            }
            if (findMappingColon(rest) != null) {
                self.lines = try self.replaceCurrent(itemIndent, rest);
                try array.append(try self.parseMapping(itemIndent, null));
                continue;
            }
            self.position += 1;
            try array.append(try parseInlineValue(self.allocator, rest, line.number));
        }
        return .{ .array = array };
    }

    //
    // Replaces the current line with the text after a sequence dash (so the entry's mapping starts at itemIndent).
    //
    fn replaceCurrent(self: *Parser, itemIndent: usize, rest: []const u8) ![]const Line {
        const copy = try self.allocator.dupe(Line, self.lines);
        copy[self.position] = .{ .indent = itemIndent, .text = rest, .number = self.lines[self.position].number };
        return copy;
    }

    //
    // Parses a block mapping whose keys are at `indent`.
    //
    fn parseMapping(self: *Parser, indent: usize, initial: ?std.json.ObjectMap) anyerror!std.json.Value {
        var object: std.json.ObjectMap = initial orelse .empty;
        while (self.position < self.lines.len) {
            const line = self.lines[self.position];
            if (line.indent != indent) {
                if (line.indent > indent) {
                    return yamlError("bad indentation of a mapping entry", line.number);
                }
                break;
            }
            if (isSequenceEntry(line.text)) {
                break;
            }
            const colon = findMappingColon(line.text) orelse {
                return yamlError("can not read a block mapping entry; a multiline key may not be an implicit key", line.number);
            };
            const key = try parseKey(self.allocator, std.mem.trimEnd(u8, line.text[0..colon], " "), line.number);
            const rest = std.mem.trimStart(u8, line.text[colon + 1 ..], " ");
            self.position += 1;
            var value: std.json.Value = undefined;
            if (rest.len == 0) {
                if (self.position < self.lines.len and self.lines[self.position].indent == indent and isSequenceEntry(self.lines[self.position].text)) {
                    // A sequence may be at the same indentation as its key.
                    value = try self.parseSequence(indent);
                }
                else {
                    value = try self.parseBlock(indent + 1);
                }
            }
            else {
                value = try parseInlineValue(self.allocator, rest, line.number);
            }
            if (object.contains(key)) {
                return yamlError("duplicated mapping key", line.number);
            }
            try object.put(self.allocator, key, value);
        }
        return .{ .object = object };
    }
};

//
// True when the text is a block sequence entry ("-" alone or followed by a space).
//
fn isSequenceEntry(text: []const u8) bool {
    return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

//
// Finds the colon that separates a mapping key from its value (followed by a space or the end of the line,
// outside quotes and flow collections), or null.
//
fn findMappingColon(text: []const u8) ?usize {
    if (text.len > 0 and (text[0] == '[' or text[0] == '{')) {
        return null;
    }
    var index: usize = 0;
    if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) {
        const quote = text[0];
        index = 1;
        while (index < text.len) {
            if (quote == '"' and text[index] == '\\') {
                index += 2;
                continue;
            }
            if (text[index] == quote) {
                if (quote == '\'' and index + 1 < text.len and text[index + 1] == '\'') {
                    index += 2;
                    continue;
                }
                index += 1;
                break;
            }
            index += 1;
        }
    }
    while (index < text.len) {
        if (text[index] == ':' and (index + 1 == text.len or text[index + 1] == ' ')) {
            return index;
        }
        index += 1;
    }
    return null;
}

//
// Parses a mapping key (a plain or quoted scalar, used as a string).
//
fn parseKey(allocator: std.mem.Allocator, text: []const u8, lineNumber: usize) ![]const u8 {
    if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) {
        const parsed = try parseQuoted(allocator, text, lineNumber);
        return parsed.value;
    }
    return text;
}

//
// A quoted scalar and the number of bytes it used.
//
const QuotedScalar = struct {
    // The unescaped value.
    value: []const u8,

    // The length of the quoted text, including the quotes.
    length: usize,
};

//
// Parses a single-quoted or double-quoted scalar at the start of the text.
//
fn parseQuoted(allocator: std.mem.Allocator, text: []const u8, lineNumber: usize) !QuotedScalar {
    const quote = text[0];
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < text.len) {
        const character = text[index];
        if (quote == '\'') {
            if (character == '\'') {
                if (index + 1 < text.len and text[index + 1] == '\'') {
                    try result.append(allocator, '\'');
                    index += 2;
                    continue;
                }
                return .{ .value = result.items, .length = index + 1 };
            }
            try result.append(allocator, character);
            index += 1;
            continue;
        }
        if (character == '"') {
            return .{ .value = result.items, .length = index + 1 };
        }
        if (character == '\\' and index + 1 < text.len) {
            const escaped = text[index + 1];
            index += 2;
            switch (escaped) {
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                'r' => try result.append(allocator, '\r'),
                '0' => try result.append(allocator, 0),
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                '/' => try result.append(allocator, '/'),
                ' ' => try result.append(allocator, ' '),
                'u', 'x', 'U' => {
                    const digits: usize = switch (escaped) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (index + digits > text.len) {
                        return yamlError("expected hexadecimal character", lineNumber);
                    }
                    const codePoint = std.fmt.parseInt(u21, text[index .. index + digits], 16) catch return yamlError("expected hexadecimal character", lineNumber);
                    var buffer: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(codePoint, &buffer) catch return yamlError("expected hexadecimal character", lineNumber);
                    try result.appendSlice(allocator, buffer[0..length]);
                    index += digits;
                },
                else => return yamlError("unknown escape sequence", lineNumber),
            }
            continue;
        }
        try result.append(allocator, character);
        index += 1;
    }
    return yamlError("unexpected end of the stream within a quoted scalar", lineNumber);
}

//
// Resolves a plain scalar with the core schema (null, booleans, integers, floats, else a string).
//
fn resolvePlain(text: []const u8) std.json.Value {
    const nulls = [_][]const u8{ "~", "null", "Null", "NULL" };
    for (nulls) |candidate| {
        if (std.mem.eql(u8, text, candidate)) {
            return .null;
        }
    }
    const trues = [_][]const u8{ "true", "True", "TRUE" };
    for (trues) |candidate| {
        if (std.mem.eql(u8, text, candidate)) {
            return .{ .bool = true };
        }
    }
    const falses = [_][]const u8{ "false", "False", "FALSE" };
    for (falses) |candidate| {
        if (std.mem.eql(u8, text, candidate)) {
            return .{ .bool = false };
        }
    }
    if (isDecimalInteger(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |integer| {
            return .{ .integer = integer };
        }
        else |_| {}
    }
    if (isFloat(text)) {
        if (std.fmt.parseFloat(f64, text)) |float| {
            return .{ .float = float };
        }
        else |_| {}
    }
    return .{ .string = text };
}

//
// True for a decimal integer ([-+]?[0-9_]+ without underscores at the start).
//
fn isDecimalInteger(text: []const u8) bool {
    var index: usize = 0;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) {
        index += 1;
    }
    if (index >= text.len) {
        return false;
    }
    while (index < text.len) {
        if (!std.ascii.isDigit(text[index])) {
            return false;
        }
        index += 1;
    }
    return true;
}

//
// True for a float ([-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?).
//
fn isFloat(text: []const u8) bool {
    var index: usize = 0;
    if (index < text.len and (text[index] == '-' or text[index] == '+')) {
        index += 1;
    }
    var digits: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) {
        index += 1;
        digits += 1;
    }
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and std.ascii.isDigit(text[index])) {
            index += 1;
            digits += 1;
        }
    }
    if (digits == 0) {
        return false;
    }
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index < text.len and (text[index] == '-' or text[index] == '+')) {
            index += 1;
        }
        var exponent_digits: usize = 0;
        while (index < text.len and std.ascii.isDigit(text[index])) {
            index += 1;
            exponent_digits += 1;
        }
        if (exponent_digits == 0) {
            return false;
        }
    }
    return index == text.len;
}

//
// Splits the items of a flow collection at top-level commas.
//
fn splitFlowItems(allocator: std.mem.Allocator, inner: []const u8) ![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    var index: usize = 0;
    var quote: u8 = 0;
    while (index < inner.len) {
        const character = inner[index];
        if (quote != 0) {
            if (character == quote) {
                quote = 0;
            }
        }
        else if (character == '"' or character == '\'') {
            quote = character;
        }
        else if (character == '[' or character == '{') {
            depth += 1;
        }
        else if ((character == ']' or character == '}') and depth > 0) {
            depth -= 1;
        }
        else if (character == ',' and depth == 0) {
            try items.append(allocator, std.mem.trim(u8, inner[start..index], " "));
            start = index + 1;
        }
        index += 1;
    }
    const last = std.mem.trim(u8, inner[start..], " ");
    if (last.len > 0) {
        try items.append(allocator, last);
    }
    return items.items;
}

//
// Parses a value written on one line: a flow collection, a quoted scalar or a plain scalar.
//
fn parseInlineValue(allocator: std.mem.Allocator, text: []const u8, lineNumber: usize) anyerror!std.json.Value {
    if (text[0] == '[') {
        if (text[text.len - 1] != ']') {
            return yamlError("unexpected end of the stream within a flow collection", lineNumber);
        }
        var array = std.json.Array.init(allocator);
        for (try splitFlowItems(allocator, text[1 .. text.len - 1])) |item| {
            try array.append(try parseInlineValue(allocator, item, lineNumber));
        }
        return .{ .array = array };
    }
    if (text[0] == '{') {
        if (text[text.len - 1] != '}') {
            return yamlError("unexpected end of the stream within a flow collection", lineNumber);
        }
        var object: std.json.ObjectMap = .empty;
        for (try splitFlowItems(allocator, text[1 .. text.len - 1])) |item| {
            const colon = findMappingColon(item) orelse {
                try object.put(allocator, try parseKey(allocator, item, lineNumber), .null);
                continue;
            };
            const key = try parseKey(allocator, std.mem.trimEnd(u8, item[0..colon], " "), lineNumber);
            const rest = std.mem.trimStart(u8, item[colon + 1 ..], " ");
            try object.put(allocator, key, if (rest.len == 0) .null else try parseInlineValue(allocator, rest, lineNumber));
        }
        return .{ .object = object };
    }
    if (text[0] == '"' or text[0] == '\'') {
        const quoted = try parseQuoted(allocator, text, lineNumber);
        if (quoted.length != text.len) {
            return yamlError("end of the stream or a document separator is expected", lineNumber);
        }
        return .{ .string = quoted.value };
    }
    if (text[0] == '|' or text[0] == '>' or text[0] == '&' or text[0] == '*' or text[0] == '!' or text[0] == '@' or text[0] == '`') {
        return yamlError("unsupported YAML construct", lineNumber);
    }
    return resolvePlain(text);
}

//
// Parses a YAML document (`yaml.load(source)`). An empty document is null.
// Values are allocated with the allocator (strings may point into source).
//
pub fn load(allocator: std.mem.Allocator, source: []const u8) !std.json.Value {
    const lines = try splitLines(allocator, source);
    var parser: Parser = .{ .allocator = allocator, .lines = lines, .position = 0 };
    if (lines.len == 0) {
        return .null;
    }
    const value = try parser.parseBlock(0);
    if (parser.position < parser.lines.len) {
        return yamlError("end of the stream or a document separator is expected", parser.lines[parser.position].number);
    }
    return value;
}

//
// True when js-yaml's dump writes the string without quotes: it would read back as the same string and uses
// no YAML indicator.
//
fn isPlainSafe(text: []const u8) bool {
    if (text.len == 0) {
        return false;
    }
    if (text[0] == ' ' or text[text.len - 1] == ' ') {
        return false;
    }
    if (std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", text[0]) != null) {
        return false;
    }
    for (text, 0..) |character, index| {
        if (character < 0x20 or character == 0x7f) {
            return false;
        }
        if (character == ':' and (index + 1 == text.len or text[index + 1] == ' ')) {
            return false;
        }
        if (character == '#' and index > 0 and text[index - 1] == ' ') {
            return false;
        }
    }
    const resolved = resolvePlain(text);
    return resolved == .string;
}

//
// True when js-yaml's dump writes the string as a literal block scalar: it has line breaks, no other
// control characters and does not start with a space.
//
fn isLiteralBlock(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, '\n') == null or text[0] == ' ') {
        return false;
    }
    for (text) |character| {
        if ((character < 0x20 and character != '\n') or character == 0x7f) {
            return false;
        }
    }
    return true;
}

//
// Writes a literal block scalar (`|-`, `|` or `|+` by the number of trailing line breaks), its lines indented
// one level deeper than `level`.
//
fn writeLiteralBlock(writer: *std.Io.Writer, text: []const u8, level: usize) !void {
    var trailing: usize = 0;
    while (trailing < text.len and text[text.len - 1 - trailing] == '\n') {
        trailing += 1;
    }
    try writer.writeAll(switch (trailing) {
        0 => "|-",
        1 => "|",
        else => "|+",
    });
    const content = text[0 .. text.len - @min(trailing, 1)];
    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |line| {
        try writer.writeByte('\n');
        if (line.len > 0) {
            try writeIndent(writer, level + 1);
            try writer.writeAll(line);
        }
    }
}

//
// Writes a string scalar the way js-yaml's dump does: plain when safe, single-quoted otherwise, and
// double-quoted when it contains characters that need escapes.
//
fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    if (isPlainSafe(text)) {
        try writer.writeAll(text);
        return;
    }
    var needsEscapes = false;
    for (text) |character| {
        if (character < 0x20 or character == 0x7f) {
            needsEscapes = true;
        }
    }
    if (!needsEscapes) {
        try writer.writeByte('\'');
        for (text) |character| {
            if (character == '\'') {
                try writer.writeAll("''");
            }
            else {
                try writer.writeByte(character);
            }
        }
        try writer.writeByte('\'');
        return;
    }
    try writer.writeByte('"');
    for (text) |character| {
        switch (character) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            else => {
                if (character < 0x20 or character == 0x7f) {
                    try writer.print("\\x{X:0>2}", .{character});
                }
                else {
                    try writer.writeByte(character);
                }
            },
        }
    }
    try writer.writeByte('"');
}

//
// Writes a scalar value.
//
fn writeScalar(writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |flag| try writer.writeAll(if (flag) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |text| try writer.writeAll(text),
        .string => |text| try writeString(writer, text),
        else => unreachable,
    }
}

//
// Writes the spaces of an indentation level.
//
fn writeIndent(writer: *std.Io.Writer, level: usize) !void {
    var index: usize = 0;
    while (index < level * 2) {
        try writer.writeByte(' ');
        index += 1;
    }
}

//
// Writes a mapping at an indentation level (js-yaml block style, 2 spaces, sequences indented under their key).
//
fn writeMapping(writer: *std.Io.Writer, object: std.json.ObjectMap, level: usize) anyerror!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try writeIndent(writer, level);
        try writeString(writer, entry.key_ptr.*);
        try writer.writeByte(':');
        try writeNested(writer, entry.value_ptr.*, level);
    }
}

//
// Writes the value of a mapping entry after its key.
//
fn writeNested(writer: *std.Io.Writer, value: std.json.Value, level: usize) anyerror!void {
    switch (value) {
        .array => |array| {
            if (array.items.len == 0) {
                try writer.writeAll(" []\n");
                return;
            }
            try writer.writeByte('\n');
            try writeSequence(writer, array, level + 1);
        },
        .object => |object| {
            if (object.count() == 0) {
                try writer.writeAll(" {}\n");
                return;
            }
            try writer.writeByte('\n');
            try writeMapping(writer, object, level + 1);
        },
        else => {
            try writer.writeByte(' ');
            if (value == .string and isLiteralBlock(value.string)) {
                try writeLiteralBlock(writer, value.string, level);
            }
            else {
                try writeScalar(writer, value);
            }
            try writer.writeByte('\n');
        },
    }
}

//
// Writes a sequence at an indentation level.
//
fn writeSequence(writer: *std.Io.Writer, array: std.json.Array, level: usize) anyerror!void {
    for (array.items) |item| {
        try writeIndent(writer, level);
        try writer.writeAll("- ");
        switch (item) {
            .array, .object => return error.UnsupportedYamlDump,
            else => {
                if (item == .string and isLiteralBlock(item.string)) {
                    try writeLiteralBlock(writer, item.string, level);
                }
                else {
                    try writeScalar(writer, item);
                }
                try writer.writeByte('\n');
            },
        }
    }
}

//
// Serializes a mapping of scalars and sequences of scalars (`yaml.dump(object)`), the shapes news-state.ts writes.
//
pub fn dump(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    const writer = &allocating_writer.writer;
    switch (value) {
        .object => |object| {
            if (object.count() == 0) {
                try writer.writeAll("{}\n");
            }
            else {
                try writeMapping(writer, object, 0);
            }
        },
        else => return error.UnsupportedYamlDump,
    }
    return allocating_writer.written();
}
