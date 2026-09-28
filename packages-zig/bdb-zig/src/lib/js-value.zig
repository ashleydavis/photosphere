const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const errors = @import("utils-zig").errors;
const js_string = @import("utils-zig").js_string;

//
// No TypeScript counterpart: the JavaScript language semantics that the bdb TypeScript code relies on implicitly
// (`String(x)`, `Number(x)`, `x < y`, `x === y`, `typeof x`, `new Date(string)`, `Date.prototype.toJSON`,
// `JSON.stringify`), applied to the values npm bson produces when it deserializes a record (see bson.zig in
// serialization-zig for how BSON types map to BsonValue).
//
// Deviations from JavaScript (documented where they apply):
// - Local time is assumed to be UTC (Date.prototype.toString and Date.parse of a date-time without an offset).
// - Date.parse only accepts the ECMAScript date time string format (ISO 8601 subset); other formats give NaN.
// - Objects compare by reference in `===`; a Zig value has no identity, so strictEquals never finds two dates,
//   documents, arrays or binaries equal (sort-index.zig emulates identity where it matters, see strictEqualsValue).
//

// The JavaScript Date functions (moved to serialization-zig's js-date.zig).
const js_date = serialization_zig.js_date;
pub const MAX_TIME_VALUE = js_date.MAX_TIME_VALUE;
pub const isValidTime = js_date.isValidTime;
pub const writeIsoString = js_date.writeIsoString;
pub const writeDateString = js_date.writeDateString;
pub const parseDate = js_date.parseDate;

//
// A JavaScript primitive produced by ToPrimitive: a number or a string.
//
pub const JsPrimitive = union(enum) {
    // A JS number (possibly NaN).
    number: f64,

    // A JS string (UTF-8).
    string: []const u8,
};

// The JavaScript number formatting (moved to serialization-zig's js-number.zig).
pub const writeNumber = serialization_zig.js_number.writeNumber;

//
// Returns `typeof value` for a deserialized BSON value (dates, documents, arrays, Long, Binary and ObjectId are objects).
//
pub fn typeOf(value: BsonValue) []const u8 {
    return switch (value) {
        .number => "number",
        .string => "string",
        .boolean => "boolean",
        .undefined => "undefined",
        else => "object",
    };
}

//
// Returns true when the value is a JS Date.
//
pub fn isDate(value: BsonValue) bool {
    return value == .date;
}

//
// Formats a value like `String(value)`.
//
pub fn toString(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeString(&output.writer, value);
    return output.written();
}

//
// Writes a value like `String(value)`.
//
pub fn writeString(writer: *std.Io.Writer, value: BsonValue) std.Io.Writer.Error!void {
    switch (value) {
        .number, .double => |number| {
            try writeNumber(writer, number);
        },
        .int32 => |number| {
            try writer.print("{d}", .{number});
        },
        .int64 => |number| {
            // Long.prototype.toString().
            try writer.print("{d}", .{number});
        },
        .string => |text| {
            try writer.writeAll(text);
        },
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .undefined => {
            try writer.writeAll("undefined");
        },
        .date => |time| {
            try writeDateString(writer, time);
        },
        .document => {
            try writer.writeAll("[object Object]");
        },
        .array => |elements| {
            // Array.prototype.join(","): null and undefined elements become empty strings.
            for (elements, 0..) |element, elementIndex| {
                if (elementIndex > 0) {
                    try writer.writeAll(",");
                }
                if (element != .null and element != .undefined) {
                    try writeString(writer, element);
                }
            }
        },
        .binary => |binary| {
            if (binary.subType == 4 and binary.data.len == 16) {
                // UUID.prototype.toString() is the dashed hex string.
                try writeUuid(writer, binary.data);
            }
            else {
                // Binary.prototype.toString() decodes the bytes as UTF-8.
                try writer.writeAll(binary.data);
            }
        },
        .objectId => |objectId| {
            try writer.print("{x}", .{&objectId});
        },
    }
}

//
// Writes 16 bytes as a lowercase dashed UUID string.
//
fn writeUuid(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.print("{x}-{x}-{x}-{x}-{x}", .{ bytes[0..4], bytes[4..6], bytes[6..8], bytes[8..10], bytes[10..16] });
}

//
// Converts a string to a number like JavaScript's StringToNumber (`Number(string)`).
//
pub fn stringToNumber(textValue: []const u8) f64 {
    var start: usize = 0;
    var end: usize = textValue.len;
    while (start < end) {
        const width = js_string.whitespaceWidthAt(textValue, start);
        if (width == 0) {
            break;
        }
        start += width;
    }
    while (end > start) {
        var trimmed = false;
        var back: usize = 1;
        while (back <= 3 and back <= end - start) : (back += 1) {
            if (js_string.whitespaceWidthAt(textValue, end - back) == back) {
                end -= back;
                trimmed = true;
                break;
            }
        }
        if (!trimmed) {
            break;
        }
    }
    const text = textValue[start..end];
    if (text.len == 0) {
        return 0;
    }
    if (text.len > 2 and text[0] == '0') {
        const radix: u8 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (radix != 0) {
            var result: f64 = 0;
            for (text[2..]) |character| {
                const digit = std.fmt.charToDigit(character, radix) catch {
                    return std.math.nan(f64);
                };
                result = result * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
            }
            return result;
        }
    }
    var body = text;
    var negative = false;
    if (body[0] == '+' or body[0] == '-') {
        negative = body[0] == '-';
        body = body[1..];
    }
    if (std.mem.eql(u8, body, "Infinity")) {
        return if (negative) -std.math.inf(f64) else std.math.inf(f64);
    }
    // StrUnsignedDecimalLiteral: digits [. digits] [e[+-]digits], or . digits [exponent].
    var index: usize = 0;
    var integerDigits: usize = 0;
    while (index < body.len and std.ascii.isDigit(body[index])) {
        index += 1;
        integerDigits += 1;
    }
    var fractionDigits: usize = 0;
    if (index < body.len and body[index] == '.') {
        index += 1;
        while (index < body.len and std.ascii.isDigit(body[index])) {
            index += 1;
            fractionDigits += 1;
        }
    }
    if (integerDigits == 0 and fractionDigits == 0) {
        return std.math.nan(f64);
    }
    if (index < body.len and (body[index] == 'e' or body[index] == 'E')) {
        index += 1;
        if (index < body.len and (body[index] == '+' or body[index] == '-')) {
            index += 1;
        }
        var exponentDigits: usize = 0;
        while (index < body.len and std.ascii.isDigit(body[index])) {
            index += 1;
            exponentDigits += 1;
        }
        if (exponentDigits == 0) {
            return std.math.nan(f64);
        }
    }
    if (index != body.len) {
        return std.math.nan(f64);
    }
    const magnitude = std.fmt.parseFloat(f64, body) catch {
        return std.math.nan(f64);
    };
    return if (negative) -magnitude else magnitude;
}

//
// Converts a value like `ToPrimitive(value, hint number)`: dates give their time value (NaN when invalid), wrapper
// objects give their number, other objects give their string form, primitives stay as they are (null, undefined and
// booleans become the number they convert to, which is what every caller of this function then does).
//
pub fn toPrimitive(allocator: std.mem.Allocator, value: BsonValue) !JsPrimitive {
    return switch (value) {
        .number, .double => |number| .{ .number = number },
        .int32 => |number| .{ .number = @floatFromInt(number) },
        .string => |text| .{ .string = text },
        .boolean => |boolean| .{ .number = if (boolean) 1 else 0 },
        .null => .{ .number = 0 },
        .undefined => .{ .number = std.math.nan(f64) },
        .date => |time| .{ .number = if (isValidTime(time)) @floatFromInt(time) else std.math.nan(f64) },
        else => .{ .string = try toString(allocator, value) },
    };
}

//
// Converts a value like `Number(value)`.
//
pub fn toNumber(allocator: std.mem.Allocator, value: BsonValue) !f64 {
    return primitiveToNumber(try toPrimitive(allocator, value));
}

//
// Converts a primitive to a number (ToNumber).
//
pub fn primitiveToNumber(primitive: JsPrimitive) f64 {
    return switch (primitive) {
        .number => |number| number,
        .string => |text| stringToNumber(text),
    };
}

//
// Iterates the UTF-16 code units of a UTF-8 string.
//
pub const Utf16Iterator = struct {
    // The UTF-8 text.
    text: []const u8,

    // The index of the next byte.
    index: usize = 0,

    // A pending low surrogate (0 when none).
    pendingLowSurrogate: u16 = 0,

    //
    // Returns the next UTF-16 code unit, or null at the end.
    //
    pub fn next(self: *Utf16Iterator) ?u16 {
        if (self.pendingLowSurrogate != 0) {
            const unit = self.pendingLowSurrogate;
            self.pendingLowSurrogate = 0;
            return unit;
        }
        if (self.index >= self.text.len) {
            return null;
        }
        const sequenceLength = std.unicode.utf8ByteSequenceLength(self.text[self.index]) catch {
            self.index += 1;
            return 0xFFFD;
        };
        if (self.index + sequenceLength > self.text.len) {
            self.index += 1;
            return 0xFFFD;
        }
        const codePoint = std.unicode.utf8Decode(self.text[self.index .. self.index + sequenceLength]) catch {
            self.index += 1;
            return 0xFFFD;
        };
        self.index += sequenceLength;
        if (codePoint < 0x10000) {
            return @intCast(codePoint);
        }
        const offset = codePoint - 0x10000;
        self.pendingLowSurrogate = @intCast(0xDC00 + (offset & 0x3FF));
        return @intCast(0xD800 + (offset >> 10));
    }
};

//
// Compares two strings by UTF-16 code units like JavaScript's `<` and the default Array.prototype.sort order.
// Returns negative, zero or positive.
//
pub fn compareUtf16(left: []const u8, right: []const u8) i32 {
    var leftUnits: Utf16Iterator = .{ .text = left };
    var rightUnits: Utf16Iterator = .{ .text = right };
    while (true) {
        const leftUnit = leftUnits.next();
        const rightUnit = rightUnits.next();
        if (leftUnit == null and rightUnit == null) {
            return 0;
        }
        if (leftUnit == null) {
            return -1;
        }
        if (rightUnit == null) {
            return 1;
        }
        if (leftUnit.? != rightUnit.?) {
            if (leftUnit.? < rightUnit.?) {
                return -1;
            }
            return 1;
        }
    }
}

//
// Returns the length of a UTF-8 string in UTF-16 code units (JavaScript's `string.length`).
//
pub fn utf16Length(text: []const u8) usize {
    var units: Utf16Iterator = .{ .text = text };
    var length: usize = 0;
    while (units.next() != null) {
        length += 1;
    }
    return length;
}

//
// Evaluates `left < right` on two primitives (the abstract relational comparison). False when either is NaN.
//
pub fn primitiveLessThan(left: JsPrimitive, right: JsPrimitive) bool {
    if (left == .string and right == .string) {
        return compareUtf16(left.string, right.string) < 0;
    }
    const leftNumber = primitiveToNumber(left);
    const rightNumber = primitiveToNumber(right);
    if (std.math.isNan(leftNumber) or std.math.isNan(rightNumber)) {
        return false;
    }
    return leftNumber < rightNumber;
}

//
// Evaluates `left === right`. Objects (dates, documents, arrays, Long, Binary, ObjectId) are compared by reference in
// JavaScript; Zig values have no identity, so they are never strictly equal here.
//
pub fn strictEquals(left: BsonValue, right: BsonValue) bool {
    switch (left) {
        .number => |number| {
            return right == .number and number == right.number;
        },
        .string => |text| {
            return right == .string and std.mem.eql(u8, text, right.string);
        },
        .boolean => |boolean| {
            return right == .boolean and boolean == right.boolean;
        },
        .null => {
            return right == .null;
        },
        .undefined => {
            return right == .undefined;
        },
        else => {
            return false;
        },
    }
}

//
// Writes a string as a JSON string literal like `JSON.stringify(string)`.
//
pub fn writeJsonString(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("\"");
    for (text) |character| {
        switch (character) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
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
    try writer.writeAll("\"");
}

//
// Applies `toJSON()` like JSON.stringify does before serializing a value: a Date becomes its ISO string (or null
// when invalid), a Binary its base64 string, a UUID its dashed hex string and an ObjectId its hex string.
// Returns the value unchanged when it has no toJSON.
//
pub fn applyToJson(allocator: std.mem.Allocator, value: BsonValue) !BsonValue {
    switch (value) {
        .date => |time| {
            if (!isValidTime(time)) {
                return .null;
            }
            var output: std.Io.Writer.Allocating = .init(allocator);
            try writeIsoString(&output.writer, time);
            return .{ .string = output.written() };
        },
        .binary => |binary| {
            if (binary.subType == 4 and binary.data.len == 16) {
                var output: std.Io.Writer.Allocating = .init(allocator);
                try writeUuid(&output.writer, binary.data);
                return .{ .string = output.written() };
            }
            const encoder = std.base64.standard.Encoder;
            const encoded = try allocator.alloc(u8, encoder.calcSize(binary.data.len));
            return .{ .string = encoder.encode(encoded, binary.data) };
        },
        .objectId => |objectId| {
            return .{ .string = try std.fmt.allocPrint(allocator, "{x}", .{&objectId}) };
        },
        .int64 => |number| {
            // A Long has no toJSON; JSON.stringify writes its own properties (high, low, unsigned).
            const bits: u64 = @bitCast(number);
            const high: i32 = @bitCast(@as(u32, @truncate(bits >> 32)));
            const low: i32 = @bitCast(@as(u32, @truncate(bits)));
            return .{ .document = try BsonDocument.fromFields(allocator, &.{
                .{ .key = "low", .value = .{ .number = @floatFromInt(low) } },
                .{ .key = "high", .value = .{ .number = @floatFromInt(high) } },
                .{ .key = "unsigned", .value = .{ .boolean = false } },
            }) };
        },
        .int32 => |number| {
            // npm bson's Int32.prototype.toJSON returns the number.
            return .{ .number = @floatFromInt(number) };
        },
        .double => |number| {
            // npm bson's Double.prototype.toJSON returns the number.
            return .{ .number = number };
        },
        else => {
            return value;
        },
    }
}

//
// Formats a value like `JSON.stringify(value, null, 2)`. Returns "undefined" when JSON.stringify returns undefined
// (so the result can be interpolated into a message like a JS template string does).
//
pub fn jsonStringifyIndented(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const written = try writeJsonIndented(allocator, &output.writer, value, 0);
    if (!written) {
        return "undefined";
    }
    return output.written();
}

//
// Writes the indentation for a nesting level (two spaces per level).
//
fn writeIndent(writer: *std.Io.Writer, level: usize) !void {
    try writer.writeAll("\n");
    var count: usize = 0;
    while (count < level) : (count += 1) {
        try writer.writeAll("  ");
    }
}

//
// Writes a value as indented JSON in insertion key order. Returns false when the value is undefined (nothing written).
//
fn writeJsonIndented(allocator: std.mem.Allocator, writer: *std.Io.Writer, rawValue: BsonValue, level: usize) !bool {
    const value = try applyToJson(allocator, rawValue);
    switch (value) {
        .undefined => {
            return false;
        },
        .number => |number| {
            if (std.math.isFinite(number)) {
                try writeNumber(writer, number);
            }
            else {
                try writer.writeAll("null");
            }
        },
        .string => |text| {
            try writeJsonString(writer, text);
        },
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .array => |elements| {
            if (elements.len == 0) {
                try writer.writeAll("[]");
                return true;
            }
            try writer.writeAll("[");
            for (elements, 0..) |element, elementIndex| {
                if (elementIndex > 0) {
                    try writer.writeAll(",");
                }
                try writeIndent(writer, level + 1);
                if (!try writeJsonIndented(allocator, writer, element, level + 1)) {
                    try writer.writeAll("null");
                }
            }
            try writeIndent(writer, level);
            try writer.writeAll("]");
        },
        .document => |document| {
            var wroteField = false;
            try writer.writeAll("{");
            for (document.fields.items) |field| {
                if (field.value == .undefined) {
                    continue;
                }
                if (wroteField) {
                    try writer.writeAll(",");
                }
                try writeIndent(writer, level + 1);
                try writeJsonString(writer, field.key);
                try writer.writeAll(": ");
                _ = try writeJsonIndented(allocator, writer, field.value, level + 1);
                wroteField = true;
            }
            if (wroteField) {
                try writeIndent(writer, level);
            }
            try writer.writeAll("}");
        },
        else => {
            try writer.writeAll("null");
        },
    }
    return true;
}

//
// Evaluates `typeof value === 'object' && value !== null && !Array.isArray(value)` (the "nested object" test of
// updateFields and updateMetadata): true for documents, dates, Long, Binary, ObjectId and the number wrappers.
//
pub fn isObject(value: BsonValue) bool {
    return std.mem.eql(u8, typeOf(value), "object") and value != .null and value != .array;
}

//
// Returns `Object.keys(value)` (also the keys `for (const key in value)` visits) for a document, a date or a number or
// boolean primitive. Throws for the other values, whose own keys are not ported.
//
pub fn objectKeys(allocator: std.mem.Allocator, value: BsonValue) ![]const []const u8 {
    switch (value) {
        .document => |document| {
            const keys = try allocator.alloc([]const u8, document.fields.items.len);
            for (document.fields.items, 0..) |field, fieldIndex| {
                keys[fieldIndex] = field.key;
            }
            return keys;
        },
        .date, .number, .boolean => {
            return &.{};
        },
        else => {
            return errors.throwError("Object.keys of a {s} value is not ported", .{@tagName(value)});
        },
    }
}

//
// Returns `value[key]` for a document (undefined when it has no such field) or a date (which has no own properties).
// Throws for the other values, whose properties are not ported.
//
pub fn getProperty(value: BsonValue, key: []const u8) !BsonValue {
    switch (value) {
        .document => |document| {
            return document.get(key) orelse .undefined;
        },
        .date => {
            return .undefined;
        },
        else => {
            return errors.throwError("Reading property {s} of a {s} value is not ported", .{ key, @tagName(value) });
        },
    }
}
