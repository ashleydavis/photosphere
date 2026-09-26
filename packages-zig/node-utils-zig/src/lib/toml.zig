const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// This file has no TypeScript counterpart: TypeScript uses the third-party `smol-toml` library.
// `parse` reads a TOML 1.0 document into a dynamic value and `stringify` is a port of smol-toml's
// `stringify`, so files written by Zig are byte-identical to files written by TypeScript.
//
// Values are represented as `std.json.Value` (like the plain JavaScript objects smol-toml returns):
// tables are `.object` (keys keep document order), arrays are `.array`, strings are `.string`,
// integers are `.integer`, floats are `.float` and booleans are `.bool`. Offset date-times, local
// date-times, local dates and local times are returned as `.string` holding the text from the document.
//

//
// The dynamic value produced by parse and consumed by stringify.
//
pub const TomlValue = std.json.Value;

//
// The maximum nesting depth accepted by stringify (smol-toml's default `maxDepth`).
//
const default_max_depth: u32 = 1000;

//
// Parses TOML text. Invalid documents throw an error whose message starts with "Invalid TOML document: ".
// Returned memory belongs to `allocator` (an arena is expected).
//
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !TomlValue {
    var parser: Parser = .{
        .allocator = allocator,
        .source = source,
        .position = 0,
        .root = .{ .object = .empty },
        .current_path = .empty,
    };
    try parser.parseDocument();
    return parser.root;
}

//
// A recursive descent TOML parser.
//
const Parser = struct {
    // Allocates the parsed values.
    allocator: std.mem.Allocator,

    // The TOML text being parsed.
    source: []const u8,

    // The index of the next unread byte of source.
    position: usize,

    // The root table.
    root: TomlValue,

    // Keys of the table selected by the most recent [table] or [[array]] header.
    current_path: std.ArrayList([]const u8),

    //
    // Throws a parse error that reports the line and column of the current position.
    //
    fn fail(self: *Parser, reason: []const u8) errors.ThrownError {
        var line: usize = 1;
        var column: usize = 1;
        const end = @min(self.position, self.source.len);
        for (self.source[0..end]) |character| {
            if (character == '\n') {
                line += 1;
                column = 1;
            }
            else {
                column += 1;
            }
        }
        return errors.throwError("Invalid TOML document: {s} (line {d}, column {d})", .{ reason, line, column });
    }

    //
    // Returns the byte at the current position, or null at the end of the source.
    //
    fn peek(self: *Parser) ?u8 {
        if (self.position >= self.source.len) {
            return null;
        }
        return self.source[self.position];
    }

    //
    // Returns true when the source continues with `text` at the current position.
    //
    fn startsWith(self: *Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.position..], text);
    }

    //
    // Skips spaces and tabs.
    //
    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |character| {
            if (character != ' ' and character != '\t') {
                break;
            }
            self.position += 1;
        }
    }

    //
    // Skips a comment (from '#' to the end of the line), if there is one.
    //
    fn skipComment(self: *Parser) void {
        if (self.peek() != '#') {
            return;
        }
        while (self.peek()) |character| {
            if (character == '\n') {
                break;
            }
            self.position += 1;
        }
    }

    //
    // Skips whitespace, newlines and comments (used between array elements).
    //
    fn skipWhitespaceCommentsAndNewlines(self: *Parser) void {
        while (true) {
            self.skipWhitespace();
            self.skipComment();
            const character = self.peek() orelse return;
            if (character == '\n') {
                self.position += 1;
            }
            else if (character == '\r' and self.position + 1 < self.source.len and self.source[self.position + 1] == '\n') {
                self.position += 2;
            }
            else {
                return;
            }
        }
    }

    //
    // Expects the end of a line (optionally after whitespace and a comment).
    //
    fn expectEndOfLine(self: *Parser) !void {
        self.skipWhitespace();
        self.skipComment();
        const character = self.peek() orelse return;
        if (character == '\n') {
            self.position += 1;
            return;
        }
        if (character == '\r' and self.position + 1 < self.source.len and self.source[self.position + 1] == '\n') {
            self.position += 2;
            return;
        }
        return self.fail("expected newline or end of document after a key/value pair or header");
    }

    //
    // Parses the whole document.
    //
    fn parseDocument(self: *Parser) !void {
        while (true) {
            self.skipWhitespaceCommentsAndNewlines();
            const character = self.peek() orelse return;
            if (character == '[') {
                if (self.startsWith("[[")) {
                    try self.parseArrayTableHeader();
                }
                else {
                    try self.parseTableHeader();
                }
            }
            else {
                const table = try self.resolveTable(&self.root.object, self.current_path.items);
                try self.parseKeyValue(table);
            }
            try self.expectEndOfLine();
        }
    }

    //
    // Parses a `[a.b.c]` header and makes that table current.
    //
    fn parseTableHeader(self: *Parser) !void {
        self.position += 1;
        self.skipWhitespace();
        const keys = try self.parseKey();
        self.skipWhitespace();
        if (self.peek() != ']') {
            return self.fail("expected ']' at the end of a table header");
        }
        self.position += 1;
        _ = try self.resolveTable(&self.root.object, keys);
        self.current_path = .fromOwnedSlice(keys);
    }

    //
    // Parses a `[[a.b]]` header, appends a new table to that array of tables and makes it current.
    //
    fn parseArrayTableHeader(self: *Parser) !void {
        self.position += 2;
        self.skipWhitespace();
        const keys = try self.parseKey();
        self.skipWhitespace();
        if (!self.startsWith("]]")) {
            return self.fail("expected ']]' at the end of an array of tables header");
        }
        self.position += 2;
        const parent = try self.resolveTable(&self.root.object, keys[0 .. keys.len - 1]);
        const last_key = keys[keys.len - 1];
        const existing = parent.getPtr(last_key);
        if (existing) |existing_value| {
            if (existing_value.* != .array) {
                return self.fail("cannot redefine a key as an array of tables");
            }
            try existing_value.array.append(.{ .object = .empty });
        }
        else {
            var array = std.json.Array.init(self.allocator);
            try array.append(.{ .object = .empty });
            try parent.put(self.allocator, last_key, .{ .array = array });
        }
        self.current_path = .fromOwnedSlice(keys);
    }

    //
    // Finds (creating when missing) the table reached by following `keys` from `start`.
    // An array of tables resolves to its last table.
    //
    fn resolveTable(self: *Parser, start: *std.json.ObjectMap, keys: []const []const u8) !*std.json.ObjectMap {
        var table = start;
        for (keys) |key| {
            const existing = table.getPtr(key);
            if (existing) |existing_value| {
                switch (existing_value.*) {
                    .object => |*child_table| {
                        table = child_table;
                    },
                    .array => |*array| {
                        if (array.items.len == 0 or array.items[array.items.len - 1] != .object) {
                            return self.fail("cannot extend a value that is not a table");
                        }
                        table = &array.items[array.items.len - 1].object;
                    },
                    else => {
                        return self.fail("cannot extend a value that is not a table");
                    },
                }
            }
            else {
                try table.put(self.allocator, key, .{ .object = .empty });
                table = &table.getPtr(key).?.object;
            }
        }
        return table;
    }

    //
    // Parses `key = value` into `table`.
    //
    fn parseKeyValue(self: *Parser, table: *std.json.ObjectMap) !void {
        const keys = try self.parseKey();
        self.skipWhitespace();
        if (self.peek() != '=') {
            return self.fail("expected '=' after a key");
        }
        self.position += 1;
        self.skipWhitespace();
        const value = try self.parseValue();
        const target = try self.resolveTable(table, keys[0 .. keys.len - 1]);
        const last_key = keys[keys.len - 1];
        if (target.contains(last_key)) {
            return self.fail("cannot redefine an existing key");
        }
        try target.put(self.allocator, last_key, value);
    }

    //
    // Parses a (possibly dotted) key into its parts.
    //
    fn parseKey(self: *Parser) ![][]const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipWhitespace();
            const character = self.peek() orelse return self.fail("expected a key");
            if (character == '"') {
                try keys.append(self.allocator, try self.parseBasicString());
            }
            else if (character == '\'') {
                try keys.append(self.allocator, try self.parseLiteralString());
            }
            else {
                const start = self.position;
                while (self.peek()) |key_character| {
                    if (!std.ascii.isAlphanumeric(key_character) and key_character != '_' and key_character != '-') {
                        break;
                    }
                    self.position += 1;
                }
                if (self.position == start) {
                    return self.fail("invalid character in a key");
                }
                try keys.append(self.allocator, self.source[start..self.position]);
            }
            self.skipWhitespace();
            if (self.peek() != '.') {
                break;
            }
            self.position += 1;
        }
        return keys.toOwnedSlice(self.allocator);
    }

    //
    // Parses any value.
    //
    fn parseValue(self: *Parser) anyerror!TomlValue {
        const character = self.peek() orelse return self.fail("expected a value");
        if (character == '"') {
            if (self.startsWith("\"\"\"")) {
                return .{ .string = try self.parseMultilineBasicString() };
            }
            return .{ .string = try self.parseBasicString() };
        }
        if (character == '\'') {
            if (self.startsWith("'''")) {
                return .{ .string = try self.parseMultilineLiteralString() };
            }
            return .{ .string = try self.parseLiteralString() };
        }
        if (character == '[') {
            return self.parseArray();
        }
        if (character == '{') {
            return self.parseInlineTable();
        }
        if (self.startsWith("true")) {
            self.position += 4;
            return .{ .bool = true };
        }
        if (self.startsWith("false")) {
            self.position += 5;
            return .{ .bool = false };
        }
        return self.parseNumberOrDate();
    }

    //
    // Parses an escape sequence (after the backslash) of a basic string into `output`.
    //
    fn parseEscape(self: *Parser, output: *std.ArrayList(u8)) !void {
        const character = self.peek() orelse return self.fail("unterminated escape sequence");
        self.position += 1;
        switch (character) {
            'b' => try output.append(self.allocator, 0x08),
            't' => try output.append(self.allocator, '\t'),
            'n' => try output.append(self.allocator, '\n'),
            'f' => try output.append(self.allocator, 0x0c),
            'r' => try output.append(self.allocator, '\r'),
            'e' => try output.append(self.allocator, 0x1b),
            '"' => try output.append(self.allocator, '"'),
            '\\' => try output.append(self.allocator, '\\'),
            'u', 'U' => {
                const digit_count: usize = if (character == 'u') 4 else 8;
                if (self.position + digit_count > self.source.len) {
                    return self.fail("invalid unicode escape");
                }
                const digits = self.source[self.position .. self.position + digit_count];
                const code_point = std.fmt.parseInt(u21, digits, 16) catch return self.fail("invalid unicode escape");
                self.position += digit_count;
                var encoded: [4]u8 = undefined;
                const encoded_length = std.unicode.utf8Encode(code_point, &encoded) catch return self.fail("invalid unicode escape");
                try output.appendSlice(self.allocator, encoded[0..encoded_length]);
            },
            else => return self.fail("unrecognized escape sequence"),
        }
    }

    //
    // Parses a basic string ("...").
    //
    fn parseBasicString(self: *Parser) ![]const u8 {
        self.position += 1;
        var output: std.ArrayList(u8) = .empty;
        while (true) {
            const character = self.peek() orelse return self.fail("unterminated string");
            self.position += 1;
            if (character == '"') {
                break;
            }
            if (character == '\n') {
                return self.fail("newlines are not allowed in strings");
            }
            if (character == '\\') {
                try self.parseEscape(&output);
            }
            else {
                try output.append(self.allocator, character);
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    //
    // Parses a literal string ('...').
    //
    fn parseLiteralString(self: *Parser) ![]const u8 {
        self.position += 1;
        const start = self.position;
        while (true) {
            const character = self.peek() orelse return self.fail("unterminated string");
            if (character == '\'') {
                break;
            }
            if (character == '\n') {
                return self.fail("newlines are not allowed in strings");
            }
            self.position += 1;
        }
        const text = self.source[start..self.position];
        self.position += 1;
        return text;
    }

    //
    // Skips the newline that may directly follow the opening delimiter of a multi-line string.
    //
    fn skipFirstNewline(self: *Parser) void {
        if (self.startsWith("\r\n")) {
            self.position += 2;
        }
        else if (self.startsWith("\n")) {
            self.position += 1;
        }
    }

    //
    // Counts consecutive `quote` bytes at the current position.
    //
    fn countQuotes(self: *Parser, quote: u8) usize {
        var count: usize = 0;
        while (self.position + count < self.source.len and self.source[self.position + count] == quote) {
            count += 1;
        }
        return count;
    }

    //
    // Parses a multi-line basic string ("""...""").
    //
    fn parseMultilineBasicString(self: *Parser) ![]const u8 {
        self.position += 3;
        self.skipFirstNewline();
        var output: std.ArrayList(u8) = .empty;
        while (true) {
            const character = self.peek() orelse return self.fail("unterminated string");
            if (character == '"') {
                const quote_count = self.countQuotes('"');
                if (quote_count >= 3) {
                    if (quote_count > 5) {
                        return self.fail("too many quotes at the end of a string");
                    }
                    try output.appendNTimes(self.allocator, '"', quote_count - 3);
                    self.position += quote_count;
                    break;
                }
                try output.appendNTimes(self.allocator, '"', quote_count);
                self.position += quote_count;
                continue;
            }
            self.position += 1;
            if (character == '\\') {
                const after_backslash = self.position;
                self.skipWhitespace();
                if (self.startsWith("\n") or self.startsWith("\r\n")) {
                    // Line ending backslash: trim the newline and all following whitespace.
                    self.skipWhitespaceAndNewlines();
                    continue;
                }
                self.position = after_backslash;
                try self.parseEscape(&output);
            }
            else {
                try output.append(self.allocator, character);
            }
        }
        return output.toOwnedSlice(self.allocator);
    }

    //
    // Skips spaces, tabs and newlines.
    //
    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.peek()) |character| {
            if (character != ' ' and character != '\t' and character != '\n' and character != '\r') {
                break;
            }
            self.position += 1;
        }
    }

    //
    // Parses a multi-line literal string ('''...''').
    //
    fn parseMultilineLiteralString(self: *Parser) ![]const u8 {
        self.position += 3;
        self.skipFirstNewline();
        const start = self.position;
        while (true) {
            const character = self.peek() orelse return self.fail("unterminated string");
            if (character == '\'') {
                const quote_count = self.countQuotes('\'');
                if (quote_count >= 3) {
                    if (quote_count > 5) {
                        return self.fail("too many quotes at the end of a string");
                    }
                    const text = self.source[start .. self.position + quote_count - 3];
                    self.position += quote_count;
                    return text;
                }
                self.position += quote_count;
                continue;
            }
            self.position += 1;
        }
    }

    //
    // Parses an array ([ ... ]), which may span lines and contain comments and a trailing comma.
    //
    fn parseArray(self: *Parser) anyerror!TomlValue {
        self.position += 1;
        var array = std.json.Array.init(self.allocator);
        while (true) {
            self.skipWhitespaceCommentsAndNewlines();
            const character = self.peek() orelse return self.fail("unterminated array");
            if (character == ']') {
                self.position += 1;
                break;
            }
            try array.append(try self.parseValue());
            self.skipWhitespaceCommentsAndNewlines();
            const separator = self.peek() orelse return self.fail("unterminated array");
            if (separator == ',') {
                self.position += 1;
            }
            else if (separator != ']') {
                return self.fail("expected ',' or ']' in an array");
            }
        }
        return .{ .array = array };
    }

    //
    // Parses an inline table ({ key = value, ... }).
    //
    fn parseInlineTable(self: *Parser) anyerror!TomlValue {
        self.position += 1;
        var table: TomlValue = .{ .object = .empty };
        self.skipWhitespace();
        if (self.peek() == '}') {
            self.position += 1;
            return table;
        }
        while (true) {
            self.skipWhitespace();
            try self.parseKeyValue(&table.object);
            self.skipWhitespace();
            const separator = self.peek() orelse return self.fail("unterminated inline table");
            self.position += 1;
            if (separator == '}') {
                break;
            }
            if (separator != ',') {
                return self.fail("expected ',' or '}' in an inline table");
            }
        }
        return table;
    }

    //
    // Returns true when `text` starts with a date (YYYY-MM-DD) or a time (HH:MM).
    //
    fn isDateOrTime(text: []const u8) bool {
        if (text.len >= 10 and std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[3]) and text[4] == '-' and text[7] == '-') {
            return true;
        }
        return text.len >= 5 and std.ascii.isDigit(text[0]) and std.ascii.isDigit(text[1]) and text[2] == ':';
    }

    //
    // Parses an integer, a float, or a date/time (returned as a string).
    //
    fn parseNumberOrDate(self: *Parser) !TomlValue {
        const start = self.position;
        while (self.peek()) |character| {
            if (character == ' ' and self.position - start == 10 and isDateOrTime(self.source[start..self.position]) and self.position + 1 < self.source.len and std.ascii.isDigit(self.source[self.position + 1])) {
                // A date and time separated by a space.
                self.position += 1;
                continue;
            }
            if (character == ' ' or character == '\t' or character == ',' or character == ']' or character == '}' or character == '#' or character == '\n' or character == '\r') {
                break;
            }
            self.position += 1;
        }
        const token = self.source[start..self.position];
        if (token.len == 0) {
            return self.fail("expected a value");
        }
        if (isDateOrTime(token)) {
            return .{ .string = token };
        }

        var sign_length: usize = 0;
        var negative = false;
        if (token[0] == '+' or token[0] == '-') {
            sign_length = 1;
            negative = token[0] == '-';
        }
        const unsigned_token = token[sign_length..];
        if (std.mem.eql(u8, unsigned_token, "inf")) {
            return .{ .float = if (negative) -std.math.inf(f64) else std.math.inf(f64) };
        }
        if (std.mem.eql(u8, unsigned_token, "nan")) {
            return .{ .float = std.math.nan(f64) };
        }

        var digits: std.ArrayList(u8) = .empty;
        for (token, 0..) |character, index| {
            if (character == '_') {
                const previous_is_digit = index > 0 and std.ascii.isHex(token[index - 1]);
                const next_is_digit = index + 1 < token.len and std.ascii.isHex(token[index + 1]);
                if (!previous_is_digit or !next_is_digit) {
                    return self.fail("invalid underscore in a number");
                }
                continue;
            }
            try digits.append(self.allocator, character);
        }
        const number_text = digits.items;
        const unsigned_number = number_text[sign_length..];

        if (unsigned_number.len > 2 and unsigned_number[0] == '0' and (unsigned_number[1] == 'x' or unsigned_number[1] == 'o' or unsigned_number[1] == 'b')) {
            if (sign_length != 0) {
                return self.fail("prefixed integers cannot have a sign");
            }
            const radix: u8 = switch (unsigned_number[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            const integer = std.fmt.parseInt(i64, unsigned_number[2..], radix) catch return self.fail("integer value cannot be represented losslessly");
            return self.safeInteger(integer);
        }

        const is_float = std.mem.indexOfAny(u8, unsigned_number, ".eE") != null;
        if (is_float) {
            const float = std.fmt.parseFloat(f64, number_text) catch return self.fail("invalid float");
            return .{ .float = float };
        }
        if (unsigned_number.len > 1 and unsigned_number[0] == '0') {
            return self.fail("leading zeros are not allowed");
        }
        for (unsigned_number) |character| {
            if (!std.ascii.isDigit(character)) {
                return self.fail("invalid value");
            }
        }
        const integer = std.fmt.parseInt(i64, number_text, 10) catch return self.fail("integer value cannot be represented losslessly");
        return self.safeInteger(integer);
    }

    //
    // Rejects integers that a JavaScript number cannot hold exactly (like smol-toml does).
    //
    fn safeInteger(self: *Parser, integer: i64) !TomlValue {
        const max_safe_integer: i64 = 9007199254740991;
        if (integer > max_safe_integer or integer < -max_safe_integer) {
            return self.fail("integer value cannot be represented losslessly");
        }
        return .{ .integer = integer };
    }
};

//
// Returns true when `key` matches smol-toml's BARE_KEY (/^[a-z0-9-_]+$/i).
//
fn isBareKey(key: []const u8) bool {
    if (key.len == 0) {
        return false;
    }
    for (key) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return false;
        }
    }
    return true;
}

//
// Writes a string the way smol-toml's formatString does: `JSON.stringify(s)` with DEL escaped as \u007f.
//
fn formatString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |character| {
        switch (character) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x7f => try writer.writeAll("\\u007f"),
            else => {
                if (character < 0x20) {
                    try writer.print("\\u{x:0>4}", .{character});
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
// Writes a key, quoting it when it is not a bare key.
//
fn formatKey(writer: *std.Io.Writer, key: []const u8) !void {
    if (isBareKey(key)) {
        try writer.writeAll(key);
    }
    else {
        try formatString(writer, key);
    }
}

//
// Formats a key (quoted when necessary) into a new string.
//
fn formatKeyAlloc(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    try formatKey(&allocating_writer.writer, key);
    return allocating_writer.written();
}

//
// Writes a float the way JavaScript's `Number.prototype.toString` does.
//
fn formatFloat(writer: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("nan");
        return;
    }
    if (std.math.isInf(value)) {
        try writer.writeAll(if (value > 0) "inf" else "-inf");
        return;
    }
    const magnitude = @abs(value);
    if (magnitude != 0 and (magnitude >= 1e21 or magnitude < 1e-6)) {
        var buffer: [64]u8 = undefined;
        const scientific = try std.fmt.bufPrint(&buffer, "{e}", .{value});
        const exponent_index = std.mem.indexOfScalar(u8, scientific, 'e').?;
        try writer.writeAll(scientific[0 .. exponent_index + 1]);
        if (scientific[exponent_index + 1] != '-') {
            try writer.writeByte('+');
        }
        try writer.writeAll(scientific[exponent_index + 1 ..]);
        return;
    }
    if (value == @trunc(value)) {
        try writer.print("{d}", .{@as(i64, @intFromFloat(value))});
        return;
    }
    try writer.print("{d}", .{value});
}

//
// Returns true when `value` should be written as an array of tables (smol-toml's isArrayOfTables).
//
fn isArrayOfTables(value: TomlValue) bool {
    if (value != .array) {
        return false;
    }
    for (value.array.items) |item| {
        if (item != .object) {
            return false;
        }
    }
    return value.array.items.len != 0;
}

//
// Throws smol-toml's error for exceeding the maximum depth.
//
fn failMaximumDepth() errors.ThrownError {
    return errors.throwError("Could not stringify the object: maximum object depth exceeded", .{});
}

//
// Writes a value (smol-toml's stringifyValue).
//
fn stringifyValue(writer: *std.Io.Writer, value: TomlValue, depth: u32) anyerror!void {
    if (depth == 0) {
        return failMaximumDepth();
    }
    switch (value) {
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try formatFloat(writer, float),
        .number_string => |number_string| try writer.writeAll(number_string),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .string => |string| try formatString(writer, string),
        .object => |object| try stringifyInlineTable(writer, object, depth),
        .array => |array| try stringifyArray(writer, array, depth),
        .null => return errors.throwError("arrays cannot contain null or undefined values", .{}),
    }
}

//
// Writes an inline table (smol-toml's stringifyInlineTable).
//
fn stringifyInlineTable(writer: *std.Io.Writer, object: std.json.ObjectMap, depth: u32) anyerror!void {
    if (object.count() == 0) {
        try writer.writeAll("{}");
        return;
    }
    try writer.writeAll("{ ");
    for (object.keys(), object.values(), 0..) |key, value, index| {
        if (index != 0) {
            try writer.writeAll(", ");
        }
        try formatKey(writer, key);
        try writer.writeAll(" = ");
        try stringifyValue(writer, value, depth - 1);
    }
    try writer.writeAll(" }");
}

//
// Writes an inline array (smol-toml's stringifyArray).
//
fn stringifyArray(writer: *std.Io.Writer, array: std.json.Array, depth: u32) anyerror!void {
    if (array.items.len == 0) {
        try writer.writeAll("[]");
        return;
    }
    try writer.writeAll("[ ");
    for (array.items, 0..) |item, index| {
        if (index != 0) {
            try writer.writeAll(", ");
        }
        if (item == .null) {
            return errors.throwError("arrays cannot contain null or undefined values", .{});
        }
        try stringifyValue(writer, item, depth - 1);
    }
    try writer.writeAll(" ]");
}

//
// Formats an array of tables (smol-toml's stringifyArrayTable).
//
fn stringifyArrayTable(allocator: std.mem.Allocator, array: std.json.Array, key: []const u8, depth: u32) anyerror![]const u8 {
    if (depth == 0) {
        return failMaximumDepth();
    }
    var result: std.ArrayList(u8) = .empty;
    for (array.items) |item| {
        if (result.items.len != 0) {
            try result.append(allocator, '\n');
        }
        try result.print(allocator, "[[{s}]]\n", .{key});
        try result.appendSlice(allocator, try stringifyTable(allocator, null, item.object, key, depth));
    }
    return result.items;
}

//
// Formats a table (smol-toml's stringifyTable). `tableKey` is null for the root table.
//
fn stringifyTable(allocator: std.mem.Allocator, tableKey: ?[]const u8, object: std.json.ObjectMap, prefix: []const u8, depth: u32) anyerror![]const u8 {
    if (depth == 0) {
        return failMaximumDepth();
    }
    var preamble_writer = std.Io.Writer.Allocating.init(allocator);
    const preamble_output = &preamble_writer.writer;
    var tables: std.ArrayList(u8) = .empty;
    for (object.keys(), object.values()) |object_key, value| {
        if (value == .null) {
            continue;
        }
        const key = try formatKeyAlloc(allocator, object_key);
        if (isArrayOfTables(value)) {
            if (tables.items.len != 0) {
                try tables.append(allocator, '\n');
            }
            const array_key = if (prefix.len != 0) try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key }) else key;
            try tables.appendSlice(allocator, try stringifyArrayTable(allocator, value.array, array_key, depth - 1));
        }
        else if (value == .object) {
            const table_key = if (prefix.len != 0) try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key }) else key;
            if (tables.items.len != 0) {
                try tables.append(allocator, '\n');
            }
            try tables.appendSlice(allocator, try stringifyTable(allocator, table_key, value.object, table_key, depth - 1));
        }
        else {
            try preamble_output.writeAll(key);
            try preamble_output.writeAll(" = ");
            try stringifyValue(preamble_output, value, depth);
            try preamble_output.writeByte('\n');
        }
    }
    var preamble: []const u8 = preamble_writer.written();

    // Create table only if necessary
    if (tableKey) |table_key| {
        if (preamble.len != 0 or tables.items.len == 0) {
            if (preamble.len != 0) {
                preamble = try std.fmt.allocPrint(allocator, "[{s}]\n{s}", .{ table_key, preamble });
            }
            else {
                preamble = try std.fmt.allocPrint(allocator, "[{s}]", .{table_key});
            }
        }
    }
    if (preamble.len != 0 and tables.items.len != 0) {
        return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ preamble, tables.items });
    }
    if (preamble.len != 0) {
        return preamble;
    }
    return tables.items;
}

//
// Converts a table to TOML text exactly like smol-toml's `stringify`.
//
pub fn stringify(allocator: std.mem.Allocator, value: TomlValue) ![]const u8 {
    if (value != .object) {
        return errors.throwError("stringify can only be called with an object", .{});
    }
    const text = try stringifyTable(allocator, null, value.object, "", default_max_depth);
    if (text.len == 0 or text[text.len - 1] != '\n') {
        return std.fmt.allocPrint(allocator, "{s}\n", .{text});
    }
    return text;
}
