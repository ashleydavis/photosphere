//
// Stand-in for the third-party `js-yaml` package (load and dump) used by fs.ts (readYaml, updateYaml) and
// news-fetcher.ts (this file has no TypeScript counterpart). The loader covers the YAML that the news feed and
// the state file use:
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
// The dumper: a port of js-yaml 4.1.0's lib/dumper.js with its default options (indent 2, lineWidth 80,
// flowLevel -1, single quotes, compatibility mode on, no sorting, no replacer), for the values a JSON value can
// hold. Strings are handled as UTF-16 code units, as JavaScript does, so widths and positions match.
// (js-yaml's anchors for an object that appears twice in the input (`&ref_0`) cannot happen here, because a
// std.json.Value is a tree.)
//

//
// The number of spaces per indentation level (state.indent).
//
const DUMP_INDENT: usize = 2;

//
// The preferred line width (state.lineWidth).
//
const DUMP_LINE_WIDTH: usize = 80;

//
// The strings YAML 1.1 read as booleans, which js-yaml quotes (DEPRECATED_BOOLEANS_SYNTAX).
//
const DEPRECATED_BOOLEANS_SYNTAX = [_][]const u8{ "y", "Y", "yes", "Yes", "YES", "on", "On", "ON", "n", "N", "no", "No", "NO", "off", "Off", "OFF" };

//
// The scalar styles of chooseScalarStyle.
//
const ScalarStyle = enum {
    // Written as it is.
    plain,

    // Written in single quotes.
    single,

    // Written as a literal block scalar (|).
    literal,

    // Written as a folded block scalar (>).
    folded,

    // Written in double quotes with escapes.
    double,
};

//
// A string as UTF-16 code units (a JavaScript string).
//
const Utf16 = []const u16;

//
// Growing UTF-16 output (the JavaScript string being built).
//
const Utf16Builder = std.ArrayList(u16);

//
// Appends ASCII text to UTF-16 output.
//
fn appendAscii(allocator: std.mem.Allocator, builder: *Utf16Builder, text: []const u8) !void {
    for (text) |character| {
        try builder.append(allocator, character);
    }
}

//
// Appends `count` spaces (common.repeat(' ', count)).
//
fn appendSpaces(allocator: std.mem.Allocator, builder: *Utf16Builder, count: usize) !void {
    var index: usize = 0;
    while (index < count) {
        try builder.append(allocator, ' ');
        index += 1;
    }
}

//
// True when the ASCII text equals the UTF-16 string.
//
fn utf16EqualsAscii(string: Utf16, text: []const u8) bool {
    if (string.len != text.len) {
        return false;
    }
    for (string, text) |unit, character| {
        if (unit != character) {
            return false;
        }
    }
    return true;
}

//
// Same as 'string'.codePointAt(pos).
//
fn codePointAt(string: Utf16, position: usize) u21 {
    const first = string[position];
    if (first >= 0xD800 and first <= 0xDBFF and position + 1 < string.len) {
        const second = string[position + 1];
        if (second >= 0xDC00 and second <= 0xDFFF) {
            return @intCast((@as(u32, first) - 0xD800) * 0x400 + second - 0xDC00 + 0x10000);
        }
    }
    return first;
}

//
// [33] s-white ::= s-space | s-tab
//
fn isWhitespace(character: u21) bool {
    return character == ' ' or character == '\t';
}

//
// Returns true if the character can be printed without escaping.
//
fn isPrintable(character: u21) bool {
    return (0x00020 <= character and character <= 0x00007E) or
        ((0x000A1 <= character and character <= 0x00D7FF) and character != 0x2028 and character != 0x2029) or
        ((0x0E000 <= character and character <= 0x00FFFD) and character != 0xFEFF) or
        (0x10000 <= character and character <= 0x10FFFF);
}

//
// ns-char ::= c-printable - b-line-feed - b-carriage-return - c-byte-order-mark
//
fn isNsCharOrWhitespace(character: u21) bool {
    return isPrintable(character) and character != 0xFEFF and character != '\r' and character != '\n';
}

//
// [130] ns-plain-char(c): whether the character can be in a plain scalar after `previous`.
//
fn isPlainSafe(character: u21, previous: ?u21, inblock: bool) bool {
    const characterIsNsCharOrWhitespace = isNsCharOrWhitespace(character);
    const characterIsNsChar = characterIsNsCharOrWhitespace and !isWhitespace(character);
    const previousIsColon = previous != null and previous.? == ':';
    const safe = if (inblock)
        characterIsNsCharOrWhitespace
    else
        characterIsNsCharOrWhitespace and character != ',' and character != '[' and character != ']' and character != '{' and character != '}';
    return (safe and character != '#' and !(previousIsColon and !characterIsNsChar)) or
        (previous != null and isNsCharOrWhitespace(previous.?) and !isWhitespace(previous.?) and character == '#') or
        (previousIsColon and characterIsNsChar);
}

//
// Simplified test for values allowed as the first character in plain style.
//
fn isPlainSafeFirst(character: u21) bool {
    if (!isPrintable(character) or character == 0xFEFF or isWhitespace(character)) {
        return false;
    }
    return std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|=>'\"%@`", if (character < 0x80) @intCast(character) else 0) == null;
}

//
// Simplified test for values allowed as the last character in plain style.
//
fn isPlainSafeLast(character: u21) bool {
    return !isWhitespace(character) and character != ':';
}

//
// Determines whether block indentation indicator is required (/^\n* /).
//
fn needIndentIndicator(string: Utf16) bool {
    var index: usize = 0;
    while (index < string.len and string[index] == '\n') {
        index += 1;
    }
    return index < string.len and string[index] == ' ';
}

//
// True for js-yaml's null resolver (resolveYamlNull).
//
fn resolvesAsNull(string: Utf16) bool {
    return string.len == 0 or utf16EqualsAscii(string, "~") or utf16EqualsAscii(string, "null") or
        utf16EqualsAscii(string, "Null") or utf16EqualsAscii(string, "NULL");
}

//
// True for js-yaml's bool resolver (resolveYamlBoolean).
//
fn resolvesAsBool(string: Utf16) bool {
    const candidates = [_][]const u8{ "true", "True", "TRUE", "false", "False", "FALSE" };
    for (candidates) |candidate| {
        if (utf16EqualsAscii(string, candidate)) {
            return true;
        }
    }
    return false;
}

//
// True for a digit of the given base (isHexCode, isOctCode, isDecCode).
//
fn isDigitOfBase(unit: u16, base: u8) bool {
    if (unit > 0x7f) {
        return false;
    }
    const character: u8 = @intCast(unit);
    return switch (base) {
        2 => character == '0' or character == '1',
        8 => character >= '0' and character <= '7',
        10 => character >= '0' and character <= '9',
        else => std.ascii.isHex(character),
    };
}

//
// True for js-yaml's int resolver (resolveYamlInteger).
//
fn resolvesAsInteger(string: Utf16) bool {
    const max = string.len;
    if (max == 0) {
        return false;
    }
    var index: usize = 0;
    var character: u16 = string[index];

    // sign
    if (character == '-' or character == '+') {
        index += 1;
        character = if (index < max) string[index] else 0;
    }

    if (character == '0') {
        // 0
        if (index + 1 == max) {
            return true;
        }
        index += 1;
        character = string[index];

        // base 2, base 8, base 16
        const base: u8 = switch (character) {
            'b' => 2,
            'x' => 16,
            'o' => 8,
            else => 0,
        };
        if (base != 0) {
            index += 1;
            var hasDigits = false;
            while (index < max) {
                character = string[index];
                index += 1;
                if (character == '_') {
                    continue;
                }
                if (!isDigitOfBase(character, base)) {
                    return false;
                }
                hasDigits = true;
            }
            return hasDigits and character != '_';
        }
    }

    // base 10 (except 0)

    // value should not start with `_`;
    if (character == '_') {
        return false;
    }

    var hasDigits = false;
    while (index < max) {
        character = string[index];
        index += 1;
        if (character == '_') {
            continue;
        }
        if (!isDigitOfBase(character, 10)) {
            return false;
        }
        hasDigits = true;
    }

    // Should have digits and should not end with `_`
    return hasDigits and character != '_';
}

//
// A cursor over a UTF-16 string for the regular expressions below.
//
const Cursor = struct {
    // The string.
    string: Utf16,

    // The position of the next unit.
    position: usize,

    //
    // Consumes the unit when it is one of the ASCII characters.
    //
    fn accept(self: *Cursor, characters: []const u8) bool {
        if (self.position < self.string.len and self.string[self.position] < 0x80 and std.mem.indexOfScalar(u8, characters, @intCast(self.string[self.position])) != null) {
            self.position += 1;
            return true;
        }
        return false;
    }

    //
    // Consumes the ASCII text when it is next.
    //
    fn acceptText(self: *Cursor, text: []const u8) bool {
        if (self.position + text.len <= self.string.len and utf16EqualsAscii(self.string[self.position .. self.position + text.len], text)) {
            self.position += text.len;
            return true;
        }
        return false;
    }

    //
    // Consumes as many of the characters as there are, returning how many.
    //
    fn acceptMany(self: *Cursor, characters: []const u8) usize {
        var count: usize = 0;
        while (self.accept(characters)) {
            count += 1;
        }
        return count;
    }

    //
    // True when the whole string has been consumed.
    //
    fn atEnd(self: *const Cursor) bool {
        return self.position == self.string.len;
    }
};

//
// The digits of YAML_FLOAT_PATTERN and the timestamp patterns.
//
const DIGITS = "0123456789";

//
// True for js-yaml's float resolver (resolveYamlFloat and YAML_FLOAT_PATTERN).
//
fn resolvesAsFloat(string: Utf16) bool {
    if (string.len == 0 or string[string.len - 1] == '_') {
        return false;
    }

    // [-+]?(?:[0-9][0-9_]*)(?:\.[0-9_]*)?(?:[eE][-+]?[0-9]+)?
    var cursor: Cursor = .{ .string = string, .position = 0 };
    _ = cursor.accept("-+");
    if (cursor.accept(DIGITS)) {
        _ = cursor.acceptMany(DIGITS ++ "_");
        if (cursor.accept(".")) {
            _ = cursor.acceptMany(DIGITS ++ "_");
        }
        if (acceptExponent(&cursor) and cursor.atEnd()) {
            return true;
        }
    }

    // \.[0-9_]+(?:[eE][-+]?[0-9]+)?
    cursor = .{ .string = string, .position = 0 };
    if (cursor.accept(".") and cursor.acceptMany(DIGITS ++ "_") > 0 and acceptExponent(&cursor) and cursor.atEnd()) {
        return true;
    }

    // [-+]?\.(?:inf|Inf|INF)
    cursor = .{ .string = string, .position = 0 };
    _ = cursor.accept("-+");
    if (cursor.acceptText(".inf") or cursor.acceptText(".Inf") or cursor.acceptText(".INF")) {
        if (cursor.atEnd()) {
            return true;
        }
    }

    // \.(?:nan|NaN|NAN)
    return utf16EqualsAscii(string, ".nan") or utf16EqualsAscii(string, ".NaN") or utf16EqualsAscii(string, ".NAN");
}

//
// Consumes an optional exponent ([eE][-+]?[0-9]+); false when an exponent is started but has no digits.
//
fn acceptExponent(cursor: *Cursor) bool {
    const start = cursor.position;
    if (!cursor.accept("eE")) {
        return true;
    }
    _ = cursor.accept("-+");
    if (cursor.acceptMany(DIGITS) == 0) {
        cursor.position = start;
        return false;
    }
    return true;
}

//
// Consumes between min and max digits.
//
fn acceptDigits(cursor: *Cursor, min: usize, max: usize) bool {
    var count: usize = 0;
    while (count < max and cursor.accept(DIGITS)) {
        count += 1;
    }
    return count >= min;
}

//
// True for js-yaml's timestamp resolver (YAML_DATE_REGEXP and YAML_TIMESTAMP_REGEXP).
//
fn resolvesAsTimestamp(string: Utf16) bool {
    // ^[0-9]{4}-[0-9]{2}-[0-9]{2}$
    var cursor: Cursor = .{ .string = string, .position = 0 };
    if (acceptDigits(&cursor, 4, 4) and cursor.accept("-") and acceptDigits(&cursor, 2, 2) and cursor.accept("-") and acceptDigits(&cursor, 2, 2) and cursor.atEnd()) {
        return true;
    }

    cursor = .{ .string = string, .position = 0 };
    if (!(acceptDigits(&cursor, 4, 4) and cursor.accept("-") and acceptDigits(&cursor, 1, 2) and cursor.accept("-") and acceptDigits(&cursor, 1, 2))) {
        return false;
    }
    // (?:[Tt]|[ \t]+)
    if (!cursor.accept("Tt") and cursor.acceptMany(" \t") == 0) {
        return false;
    }
    // hour:minute:second
    if (!(acceptDigits(&cursor, 1, 2) and cursor.accept(":") and acceptDigits(&cursor, 2, 2) and cursor.accept(":") and acceptDigits(&cursor, 2, 2))) {
        return false;
    }
    // (?:\.([0-9]*))?
    if (cursor.accept(".")) {
        _ = cursor.acceptMany(DIGITS);
    }
    if (cursor.atEnd()) {
        return true;
    }
    // (?:[ \t]*(Z|([-+])([0-9][0-9]?)(?::([0-9][0-9]))?))?$
    _ = cursor.acceptMany(" \t");
    if (cursor.accept("Z")) {
        return cursor.atEnd();
    }
    if (!cursor.accept("-+") or !acceptDigits(&cursor, 1, 2)) {
        return false;
    }
    if (cursor.accept(":") and !acceptDigits(&cursor, 2, 2)) {
        return false;
    }
    return cursor.atEnd();
}

//
// Whether the string would read back as another type (testImplicitResolving over the default schema's
// implicit types: null, bool, int, float, timestamp and merge).
//
fn testImplicitResolving(string: Utf16) bool {
    return resolvesAsNull(string) or resolvesAsBool(string) or resolvesAsInteger(string) or resolvesAsFloat(string) or
        resolvesAsTimestamp(string) or utf16EqualsAscii(string, "<<");
}

//
// True for DEPRECATED_BASE60_SYNTAX (/^[-+]?[0-9_]+(?::[0-9_]+)+(?:\.[0-9_]*)?$/).
//
fn isDeprecatedBase60(string: Utf16) bool {
    var cursor: Cursor = .{ .string = string, .position = 0 };
    _ = cursor.accept("-+");
    if (cursor.acceptMany(DIGITS ++ "_") == 0) {
        return false;
    }
    var groups: usize = 0;
    while (cursor.accept(":")) {
        if (cursor.acceptMany(DIGITS ++ "_") == 0) {
            return false;
        }
        groups += 1;
    }
    if (groups == 0) {
        return false;
    }
    if (cursor.accept(".")) {
        _ = cursor.acceptMany(DIGITS ++ "_");
    }
    return cursor.atEnd();
}

//
// Determines which scalar styles are possible and returns the preferred style (quoting type single, no forced
// quotes).
//
fn chooseScalarStyle(string: Utf16, singleLineOnly: bool, indentPerLevel: usize, lineWidth: usize, inblock: bool) ScalarStyle {
    var index: usize = 0;
    var character: u21 = 0;
    var previousCharacter: ?u21 = null;
    var hasLineBreak = false;
    var hasFoldableLine = false;
    var previousLineBreak: isize = -1;
    var plain = isPlainSafeFirst(codePointAt(string, 0)) and isPlainSafeLast(codePointAt(string, string.len - 1));

    if (singleLineOnly) {
        // Case: no block styles.
        // Check for disallowed characters to rule out plain and single.
        while (index < string.len) {
            character = codePointAt(string, index);
            if (!isPrintable(character)) {
                return .double;
            }
            plain = plain and isPlainSafe(character, previousCharacter, inblock);
            previousCharacter = character;
            index += if (character >= 0x10000) 2 else 1;
        }
    }
    else {
        // Case: block styles permitted.
        while (index < string.len) {
            character = codePointAt(string, index);
            if (character == '\n') {
                hasLineBreak = true;
                // Check if any line can be folded.
                hasFoldableLine = hasFoldableLine or
                    // Foldable line = too long, and not more-indented.
                    (@as(isize, @intCast(index)) - previousLineBreak - 1 > @as(isize, @intCast(lineWidth)) and
                        string[@intCast(previousLineBreak + 1)] != ' ');
                previousLineBreak = @intCast(index);
            }
            else if (!isPrintable(character)) {
                return .double;
            }
            plain = plain and isPlainSafe(character, previousCharacter, inblock);
            previousCharacter = character;
            index += if (character >= 0x10000) 2 else 1;
        }
        // in case the end is missing a \n
        hasFoldableLine = hasFoldableLine or
            (@as(isize, @intCast(index)) - previousLineBreak - 1 > @as(isize, @intCast(lineWidth)) and
                string[@intCast(previousLineBreak + 1)] != ' ');
    }
    // Although every style can represent \n without escaping, prefer block styles
    // for multiline, since they're more readable and they don't add empty lines.
    // Also prefer folding a super-long line.
    if (!hasLineBreak and !hasFoldableLine) {
        // Strings interpretable as another type have to be quoted;
        // e.g. the string 'true' vs. the boolean true.
        if (plain and !testImplicitResolving(string)) {
            return .plain;
        }
        return .single;
    }
    // Edge case: block indentation indicator can only have one digit.
    if (indentPerLevel > 9 and needIndentIndicator(string)) {
        return .double;
    }
    // At this point we know block styles are valid.
    // Prefer literal style unless we want to fold.
    return if (hasFoldableLine) .folded else .literal;
}

//
// The header of a block scalar: the indentation indicator when needed and the chomping indicator.
//
fn blockHeader(allocator: std.mem.Allocator, builder: *Utf16Builder, string: Utf16, indentPerLevel: usize) !void {
    if (needIndentIndicator(string)) {
        try builder.append(allocator, @intCast('0' + indentPerLevel));
    }

    // note the special case: the string '\n' counts as a "trailing" empty line.
    const clip = string[string.len - 1] == '\n';
    const keep = clip and ((string.len >= 2 and string[string.len - 2] == '\n') or string.len == 1);
    if (keep) {
        try builder.append(allocator, '+');
    }
    else if (!clip) {
        try builder.append(allocator, '-');
    }
    try builder.append(allocator, '\n');
}

//
// Indents every line in a string. Empty lines (\n only) are not indented.
//
fn indentString(allocator: std.mem.Allocator, string: Utf16, spaces: usize) !Utf16 {
    var result: Utf16Builder = .empty;
    var position: usize = 0;
    while (position < string.len) {
        const next = std.mem.indexOfScalarPos(u16, string, position, '\n');
        var line: Utf16 = undefined;
        if (next) |lineFeed| {
            line = string[position .. lineFeed + 1];
            position = lineFeed + 1;
        }
        else {
            line = string[position..];
            position = string.len;
        }
        if (line.len > 0 and !(line.len == 1 and line[0] == '\n')) {
            try appendSpaces(allocator, &result, spaces);
        }
        try result.appendSlice(allocator, line);
    }
    return result.items;
}

//
// Drops the last line feed of a block scalar (the dumper adds its own).
//
fn dropEndingNewline(string: Utf16) Utf16 {
    if (string.len > 0 and string[string.len - 1] == '\n') {
        return string[0 .. string.len - 1];
    }
    return string;
}

//
// Greedy line breaking: picks the longest line under the limit each time, otherwise settles for the shortest
// line over the limit. More-indented lines cannot be folded.
//
fn foldLine(allocator: std.mem.Allocator, line: Utf16, width: usize) !Utf16 {
    if (line.len == 0 or line[0] == ' ') {
        return line;
    }

    var start: usize = 0;
    var current: usize = 0;
    var result: Utf16Builder = .empty;

    // Since a more-indented line adds a \n, breaks can't be followed by a space (/ [^ ]/g).
    var searchFrom: usize = 0;
    while (searchFrom + 1 < line.len) {
        if (line[searchFrom] != ' ' or line[searchFrom + 1] == ' ') {
            searchFrom += 1;
            continue;
        }
        const next = searchFrom;
        searchFrom += 2;
        // maintain invariant: curr - start <= width
        if (next - start > width) {
            const end = if (current > start) current else next;
            try result.append(allocator, '\n');
            try result.appendSlice(allocator, line[start..end]);
            // skip the space that was output as \n
            start = end + 1;
        }
        current = next;
    }

    // By the invariants, start <= length-1, so there is something left over.
    try result.append(allocator, '\n');
    // Insert a break if the remainder is too long and there is a break available.
    if (line.len - start > width and current > start) {
        try result.appendSlice(allocator, line[start..current]);
        try result.append(allocator, '\n');
        try result.appendSlice(allocator, line[current + 1 ..]);
    }
    else {
        try result.appendSlice(allocator, line[start..]);
    }

    return result.items[1..]; // drop extra \n joiner
}

//
// Folds a string for the folded style: consecutive line feeds are kept apart from the lines around them.
//
fn foldString(allocator: std.mem.Allocator, string: Utf16, width: usize) !Utf16 {
    var result: Utf16Builder = .empty;

    // first line (possibly an empty line)
    const firstLineFeed = std.mem.indexOfScalar(u16, string, '\n') orelse string.len;
    try result.appendSlice(allocator, try foldLine(allocator, string[0..firstLineFeed], width));

    // If we haven't reached the first content line yet, don't add an extra \n.
    var previousMoreIndented = string[0] == '\n' or string[0] == ' ';

    // rest of the lines (/(\n+)([^\n]*)/g)
    var position = firstLineFeed;
    while (position < string.len) {
        const prefixStart = position;
        while (position < string.len and string[position] == '\n') {
            position += 1;
        }
        const prefix = string[prefixStart..position];
        const lineStart = position;
        while (position < string.len and string[position] != '\n') {
            position += 1;
        }
        const line = string[lineStart..position];
        const moreIndented = line.len > 0 and line[0] == ' ';
        try result.appendSlice(allocator, prefix);
        if (!previousMoreIndented and !moreIndented and line.len > 0) {
            try result.append(allocator, '\n');
        }
        try result.appendSlice(allocator, try foldLine(allocator, line, width));
        previousMoreIndented = moreIndented;
    }

    return result.items;
}

//
// Escapes a double-quoted string.
//
fn escapeString(allocator: std.mem.Allocator, builder: *Utf16Builder, string: Utf16) !void {
    var index: usize = 0;
    while (index < string.len) {
        const character = codePointAt(string, index);
        const escapeSequence: ?[]const u8 = switch (character) {
            0x00 => "\\0",
            0x07 => "\\a",
            0x08 => "\\b",
            0x09 => "\\t",
            0x0A => "\\n",
            0x0B => "\\v",
            0x0C => "\\f",
            0x0D => "\\r",
            0x1B => "\\e",
            0x22 => "\\\"",
            0x5C => "\\\\",
            0x85 => "\\N",
            0xA0 => "\\_",
            0x2028 => "\\L",
            0x2029 => "\\P",
            else => null,
        };
        if (escapeSequence == null and isPrintable(character)) {
            try builder.append(allocator, string[index]);
            if (character >= 0x10000) {
                try builder.append(allocator, string[index + 1]);
            }
        }
        else if (escapeSequence) |sequence| {
            try appendAscii(allocator, builder, sequence);
        }
        else {
            // encodeHex
            var buffer: [16]u8 = undefined;
            const encoded = if (character <= 0xFF)
                try std.fmt.bufPrint(&buffer, "\\x{X:0>2}", .{character})
            else if (character <= 0xFFFF)
                try std.fmt.bufPrint(&buffer, "\\u{X:0>4}", .{character})
            else
                try std.fmt.bufPrint(&buffer, "\\U{X:0>8}", .{character});
            try appendAscii(allocator, builder, encoded);
        }
        index += if (character >= 0x10000) 2 else 1;
    }
}

//
// Writes a string scalar (writeScalar).
//
fn writeScalar(allocator: std.mem.Allocator, string: Utf16, level: usize, iskey: bool, inblock: bool) !Utf16 {
    var builder: Utf16Builder = .empty;
    if (string.len == 0) {
        try appendAscii(allocator, &builder, "''");
        return builder.items;
    }
    for (DEPRECATED_BOOLEANS_SYNTAX) |deprecated| {
        if (utf16EqualsAscii(string, deprecated)) {
            try builder.append(allocator, '\'');
            try builder.appendSlice(allocator, string);
            try builder.append(allocator, '\'');
            return builder.items;
        }
    }
    if (isDeprecatedBase60(string)) {
        try builder.append(allocator, '\'');
        try builder.appendSlice(allocator, string);
        try builder.append(allocator, '\'');
        return builder.items;
    }

    const indent = DUMP_INDENT * @max(1, level); // no 0-indent scalars
    // As indentation gets deeper, let the width decrease monotonically
    // to the lower bound min(state.lineWidth, 40).
    const lineWidth = @max(@min(DUMP_LINE_WIDTH, 40), DUMP_LINE_WIDTH -| indent);

    // Without knowing if keys are implicit/explicit, assume implicit for safety.
    const singleLineOnly = iskey;

    switch (chooseScalarStyle(string, singleLineOnly, DUMP_INDENT, lineWidth, inblock)) {
        .plain => try builder.appendSlice(allocator, string),
        .single => {
            try builder.append(allocator, '\'');
            for (string) |unit| {
                if (unit == '\'') {
                    try appendAscii(allocator, &builder, "''");
                }
                else {
                    try builder.append(allocator, unit);
                }
            }
            try builder.append(allocator, '\'');
        },
        .literal => {
            try builder.append(allocator, '|');
            try blockHeader(allocator, &builder, string, DUMP_INDENT);
            try builder.appendSlice(allocator, dropEndingNewline(try indentString(allocator, string, indent)));
        },
        .folded => {
            try builder.append(allocator, '>');
            try blockHeader(allocator, &builder, string, DUMP_INDENT);
            try builder.appendSlice(allocator, dropEndingNewline(try indentString(allocator, try foldString(allocator, string, lineWidth), indent)));
        },
        .double => {
            try builder.append(allocator, '"');
            try escapeString(allocator, &builder, string);
            try builder.append(allocator, '"');
        },
    }
    return builder.items;
}

//
// Appends generateNextLine(state, level): a line feed and the indentation of the level.
//
fn appendNextLine(allocator: std.mem.Allocator, builder: *Utf16Builder, level: usize) !void {
    try builder.append(allocator, '\n');
    try appendSpaces(allocator, builder, DUMP_INDENT * level);
}

//
// Writes a block sequence (writeBlockSequence).
//
fn writeBlockSequence(allocator: std.mem.Allocator, level: usize, array: std.json.Array, compact: bool) anyerror!Utf16 {
    var result: Utf16Builder = .empty;
    for (array.items) |value| {
        const dumped = try writeNode(allocator, level + 1, value, true, true, false);
        if (!compact or result.items.len > 0) {
            try appendNextLine(allocator, &result, level);
        }
        if (dumped.len > 0 and dumped[0] == '\n') {
            try result.append(allocator, '-');
        }
        else {
            try appendAscii(allocator, &result, "- ");
        }
        try result.appendSlice(allocator, dumped);
    }
    return result.items;
}

//
// The array index a key names (a canonical decimal below 2^32 - 1), or null.
//
fn arrayIndexOf(key: []const u8) ?u32 {
    if (key.len == 0 or (key.len > 1 and key[0] == '0')) {
        return null;
    }
    const index = std.fmt.parseInt(u32, key, 10) catch {
        return null;
    };
    if (index == std.math.maxInt(u32)) {
        return null;
    }
    return index;
}

//
// Orders array index keys by their index before the other keys (a JavaScript object's own keys come out
// of Object.keys that way).
//
fn keyOrderLessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    const leftIndex = arrayIndexOf(left) orelse {
        return false;
    };
    const rightIndex = arrayIndexOf(right) orelse {
        return true;
    };
    return leftIndex < rightIndex;
}

//
// Writes a block mapping (writeBlockMapping). The keys are taken in the order Object.keys gives them.
//
fn writeBlockMapping(allocator: std.mem.Allocator, level: usize, object: std.json.ObjectMap, compact: bool) anyerror!Utf16 {
    var result: Utf16Builder = .empty;
    const objectKeyList = try allocator.dupe([]const u8, object.keys());
    std.sort.insertion([]const u8, objectKeyList, {}, keyOrderLessThan);
    for (objectKeyList) |objectKey| {
        const entry = .{ .key_ptr = &objectKey, .value_ptr = object.getPtr(objectKey).? };
        var pair: Utf16Builder = .empty;
        if (!compact or result.items.len > 0) {
            try appendNextLine(allocator, &pair, level);
        }

        const dumpedKey = try writeNode(allocator, level + 1, .{ .string = entry.key_ptr.* }, true, true, true);
        const explicitPair = dumpedKey.len > 1024;
        if (explicitPair) {
            if (dumpedKey.len > 0 and dumpedKey[0] == '\n') {
                try pair.append(allocator, '?');
            }
            else {
                try appendAscii(allocator, &pair, "? ");
            }
        }
        try pair.appendSlice(allocator, dumpedKey);
        if (explicitPair) {
            try appendNextLine(allocator, &pair, level);
        }

        const dumpedValue = try writeNode(allocator, level + 1, entry.value_ptr.*, true, explicitPair, false);
        if (dumpedValue.len > 0 and dumpedValue[0] == '\n') {
            try pair.append(allocator, ':');
        }
        else {
            try appendAscii(allocator, &pair, ": ");
        }
        try pair.appendSlice(allocator, dumpedValue);

        // Both key and value are valid.
        try result.appendSlice(allocator, pair.items);
    }
    return result.items;
}

//
// Represents a number the way js-yaml's int and float types do.
// (Zig: a finite number is written in Zig's shortest decimal form, which is JavaScript's Number#toString for every
// number from 1e-6 up to 1e21, the range the state files hold.)
//
fn representNumber(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .integer => |integer| return std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| {
            if (std.math.isNan(float)) {
                return ".nan";
            }
            if (std.math.isInf(float)) {
                return if (float > 0) ".inf" else "-.inf";
            }
            if (float == 0 and std.math.signbit(float)) {
                return "-0.0";
            }
            if (@floor(float) == float and @abs(float) < 1e21) {
                // Number.isInteger: the int type's representer.
                return std.fmt.allocPrint(allocator, "{d}", .{@as(i128, @intFromFloat(float))});
            }
            return std.fmt.allocPrint(allocator, "{d}", .{float});
        },
        .number_string => |text| return text,
        else => unreachable,
    }
}

//
// Serializes a value (writeNode) and returns what it dumped. `block` is the block flag, which with flowLevel -1
// stays as given; a flow collection is therefore only ever an empty one.
//
fn writeNode(allocator: std.mem.Allocator, level: usize, value: std.json.Value, block: bool, compact: bool, iskey: bool) anyerror!Utf16 {
    var builder: Utf16Builder = .empty;
    switch (value) {
        .null => try appendAscii(allocator, &builder, "null"),
        .bool => |flag| try appendAscii(allocator, &builder, if (flag) "true" else "false"),
        .integer, .float, .number_string => try appendAscii(allocator, &builder, try representNumber(allocator, value)),
        .string => |text| return writeScalar(allocator, try std.unicode.utf8ToUtf16LeAlloc(allocator, text), level, iskey, block),
        .object => |object| {
            if (block and object.count() != 0) {
                return writeBlockMapping(allocator, level, object, compact);
            }
            try appendAscii(allocator, &builder, "{}");
        },
        .array => |array| {
            if (block and array.items.len != 0) {
                return writeBlockSequence(allocator, level, array, compact);
            }
            try appendAscii(allocator, &builder, "[]");
        },
    }
    return builder.items;
}

//
// Serializes a value to YAML (`yaml.dump(value)` with the default options).
//
pub fn dump(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const dumped = try writeNode(allocator, 0, value, true, true, false);
    var result: Utf16Builder = .empty;
    try result.appendSlice(allocator, dumped);
    try result.append(allocator, '\n');
    return std.unicode.utf16LeToUtf8Alloc(allocator, result.items);
}
