const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;

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

//
// The largest absolute time value a JavaScript Date holds (8.64e15 milliseconds).
//
pub const MAX_TIME_VALUE: i64 = 8_640_000_000_000_000;

//
// A JavaScript primitive produced by ToPrimitive: a number or a string.
//
pub const JsPrimitive = union(enum) {
    // A JS number (possibly NaN).
    number: f64,

    // A JS string (UTF-8).
    string: []const u8,
};

//
// Writes a JS number like `Number.prototype.toString()`: shortest round-trip digits, decimal notation for exponents
// in [-7, 21), exponential notation (`1e+21`, `1.5e-7`) otherwise.
//
pub fn writeNumber(writer: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("NaN");
        return;
    }
    if (std.math.isInf(value)) {
        if (value < 0) {
            try writer.writeAll("-Infinity");
        }
        else {
            try writer.writeAll("Infinity");
        }
        return;
    }
    if (value == 0) {
        try writer.writeAll("0");
        return;
    }

    var buffer: [std.fmt.float.min_buffer_size]u8 = undefined;
    const scientific = std.fmt.float.render(&buffer, @abs(value), .{ .mode = .scientific }) catch unreachable;
    const exponentIndex = std.mem.indexOfScalar(u8, scientific, 'e') orelse unreachable;
    var digitBuffer: [32]u8 = undefined;
    var digitCount: usize = 0;
    for (scientific[0..exponentIndex]) |character| {
        if (character != '.') {
            digitBuffer[digitCount] = character;
            digitCount += 1;
        }
    }
    while (digitCount > 1 and digitBuffer[digitCount - 1] == '0') {
        digitCount -= 1;
    }
    const digits = digitBuffer[0..digitCount];
    const exponent = std.fmt.parseInt(i32, scientific[exponentIndex + 1 ..], 10) catch unreachable;

    // n is the position of the decimal point relative to the digits (ECMAScript Number::toString).
    const pointPosition: i32 = exponent + 1;
    const digitLength: i32 = @intCast(digits.len);

    if (value < 0) {
        try writer.writeAll("-");
    }

    if (digitLength <= pointPosition and pointPosition <= 21) {
        try writer.writeAll(digits);
        var zeros = pointPosition - digitLength;
        while (zeros > 0) {
            try writer.writeAll("0");
            zeros -= 1;
        }
        return;
    }
    if (0 < pointPosition and pointPosition <= 21) {
        const split: usize = @intCast(pointPosition);
        try writer.writeAll(digits[0..split]);
        try writer.writeAll(".");
        try writer.writeAll(digits[split..]);
        return;
    }
    if (-6 < pointPosition and pointPosition <= 0) {
        try writer.writeAll("0.");
        var zeros = -pointPosition;
        while (zeros > 0) {
            try writer.writeAll("0");
            zeros -= 1;
        }
        try writer.writeAll(digits);
        return;
    }
    try writer.writeAll(digits[0..1]);
    if (digits.len > 1) {
        try writer.writeAll(".");
        try writer.writeAll(digits[1..]);
    }
    const shownExponent = pointPosition - 1;
    if (shownExponent >= 0) {
        try writer.print("e+{d}", .{shownExponent});
    }
    else {
        try writer.print("e-{d}", .{-shownExponent});
    }
}

//
// Returns true when a time value (milliseconds since the epoch) is a valid JS Date.
//
pub fn isValidTime(milliseconds: i64) bool {
    return milliseconds >= -MAX_TIME_VALUE and milliseconds <= MAX_TIME_VALUE;
}

//
// A calendar date and time of day in UTC.
//
const DateParts = struct {
    // The year (may be negative or above 9999).
    year: i64,

    // The month (1 to 12).
    month: u8,

    // The day of the month (1 to 31).
    day: u8,

    // The day of the week (0 = Sunday).
    weekDay: u8,

    // The hours (0 to 23).
    hours: u8,

    // The minutes (0 to 59).
    minutes: u8,

    // The seconds (0 to 59).
    seconds: u8,

    // The milliseconds (0 to 999).
    milliseconds: u16,
};

//
// Splits a time value into its UTC calendar parts (Howard Hinnant's civil_from_days algorithm).
//
fn dateParts(time: i64) DateParts {
    const millisecondsPerDay: i64 = 24 * 60 * 60 * 1000;
    const days = @divFloor(time, millisecondsPerDay);
    const millisecondOfDay = @mod(time, millisecondsPerDay);
    const shiftedDays = days + 719468;
    const era = @divFloor(shiftedDays, 146097);
    const dayOfEra = shiftedDays - era * 146097;
    const yearOfEra = @divFloor(dayOfEra - @divFloor(dayOfEra, 1460) + @divFloor(dayOfEra, 36524) - @divFloor(dayOfEra, 146096), 365);
    const dayOfYear = dayOfEra - (365 * yearOfEra + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100));
    const monthIndex = @divFloor(5 * dayOfYear + 2, 153);
    const day = dayOfYear - @divFloor(153 * monthIndex + 2, 5) + 1;
    const month = if (monthIndex < 10) monthIndex + 3 else monthIndex - 9;
    const year = yearOfEra + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{
        .year = year,
        .month = @intCast(month),
        .day = @intCast(day),
        .weekDay = @intCast(@mod(days + 4, 7)),
        .hours = @intCast(@divFloor(millisecondOfDay, 60 * 60 * 1000)),
        .minutes = @intCast(@mod(@divFloor(millisecondOfDay, 60 * 1000), 60)),
        .seconds = @intCast(@mod(@divFloor(millisecondOfDay, 1000), 60)),
        .milliseconds = @intCast(@mod(millisecondOfDay, 1000)),
    };
}

//
// Converts a UTC calendar date to days since 1970-01-01 (Howard Hinnant's days_from_civil algorithm).
//
fn daysFromCivil(yearValue: i64, month: i64, day: i64) i64 {
    const year = if (month <= 2) yearValue - 1 else yearValue;
    const era = @divFloor(year, 400);
    const yearOfEra = year - era * 400;
    const shiftedMonth = if (month > 2) month - 3 else month + 9;
    const dayOfYear = @divFloor(153 * shiftedMonth + 2, 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100) + dayOfYear;
    return era * 146097 + dayOfEra - 719468;
}

//
// Formats a valid time value like `Date.prototype.toISOString()` (YYYY-MM-DDTHH:mm:ss.sssZ, or the expanded
// +YYYYYY / -YYYYYY year form outside 0 to 9999).
//
pub fn writeIsoString(writer: *std.Io.Writer, time: i64) !void {
    const parts = dateParts(time);
    if (parts.year >= 0 and parts.year <= 9999) {
        try writer.print("{d:0>4}", .{@as(u64, @intCast(parts.year))});
    }
    else if (parts.year < 0) {
        try writer.print("-{d:0>6}", .{@as(u64, @intCast(-parts.year))});
    }
    else {
        try writer.print("+{d:0>6}", .{@as(u64, @intCast(parts.year))});
    }
    try writer.print("-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ parts.month, parts.day, parts.hours, parts.minutes, parts.seconds, parts.milliseconds });
}

//
// The English day names used by Date.prototype.toString.
//
const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

//
// The English month names used by Date.prototype.toString.
//
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

//
// Formats a time value like `Date.prototype.toString()` with the local time zone assumed to be UTC
// (for example "Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)").
//
pub fn writeDateString(writer: *std.Io.Writer, time: i64) !void {
    if (!isValidTime(time)) {
        try writer.writeAll("Invalid Date");
        return;
    }
    const parts = dateParts(time);
    try writer.print("{s} {s} {d:0>2} ", .{ day_names[parts.weekDay], month_names[parts.month - 1], parts.day });
    if (parts.year < 0) {
        try writer.print("-{d:0>4}", .{@as(u64, @intCast(-parts.year))});
    }
    else {
        try writer.print("{d:0>4}", .{@as(u64, @intCast(parts.year))});
    }
    try writer.print(" {d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{ parts.hours, parts.minutes, parts.seconds });
}

//
// Reads a fixed number of decimal digits at index (advancing it), or null when they are not all digits.
//
fn readDigits(text: []const u8, index: *usize, count: usize) ?i64 {
    if (index.* + count > text.len) {
        return null;
    }
    var result: i64 = 0;
    for (text[index.* .. index.* + count]) |character| {
        if (!std.ascii.isDigit(character)) {
            return null;
        }
        result = result * 10 + (character - '0');
    }
    index.* += count;
    return result;
}

//
// Returns true when the character at index is `expected` (advancing past it).
//
fn consume(text: []const u8, index: *usize, expected: u8) bool {
    if (index.* < text.len and text[index.*] == expected) {
        index.* += 1;
        return true;
    }
    return false;
}

//
// Parses a string like `Date.parse` / `new Date(string).getTime()`, returning NaN when it is not a date.
// Accepts the ECMAScript date time string format: YYYY, YYYY-MM, YYYY-MM-DD, each optionally followed by
// THH:mm, THH:mm:ss or THH:mm:ss.sss (any number of fraction digits) and Z or +HH:mm / -HH:mm, with the expanded
// +YYYYYY / -YYYYYY year. A date-only form is UTC; a date-time without an offset is local time, assumed to be UTC.
//
pub fn parseDate(text: []const u8) f64 {
    var index: usize = 0;
    var year: i64 = undefined;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        const negative = text[0] == '-';
        index = 1;
        const expandedYear = readDigits(text, &index, 6) orelse {
            return std.math.nan(f64);
        };
        if (negative and expandedYear == 0) {
            return std.math.nan(f64);
        }
        year = if (negative) -expandedYear else expandedYear;
    }
    else {
        year = readDigits(text, &index, 4) orelse {
            return std.math.nan(f64);
        };
    }
    var month: i64 = 1;
    var day: i64 = 1;
    var hours: i64 = 0;
    var minutes: i64 = 0;
    var seconds: i64 = 0;
    var milliseconds: i64 = 0;
    var offsetMinutes: i64 = 0;
    if (consume(text, &index, '-')) {
        month = readDigits(text, &index, 2) orelse {
            return std.math.nan(f64);
        };
        if (consume(text, &index, '-')) {
            day = readDigits(text, &index, 2) orelse {
                return std.math.nan(f64);
            };
        }
    }
    if (consume(text, &index, 'T') or consume(text, &index, 't')) {
        hours = readDigits(text, &index, 2) orelse {
            return std.math.nan(f64);
        };
        if (!consume(text, &index, ':')) {
            return std.math.nan(f64);
        }
        minutes = readDigits(text, &index, 2) orelse {
            return std.math.nan(f64);
        };
        if (consume(text, &index, ':')) {
            seconds = readDigits(text, &index, 2) orelse {
                return std.math.nan(f64);
            };
            if (consume(text, &index, '.')) {
                var fractionDigits: usize = 0;
                var scale: i64 = 100;
                while (index < text.len and std.ascii.isDigit(text[index])) {
                    milliseconds += (text[index] - '0') * scale;
                    scale = @divTrunc(scale, 10);
                    index += 1;
                    fractionDigits += 1;
                }
                if (fractionDigits == 0) {
                    return std.math.nan(f64);
                }
            }
        }
        if (consume(text, &index, 'Z') or consume(text, &index, 'z')) {
            offsetMinutes = 0;
        }
        else if (index < text.len and (text[index] == '+' or text[index] == '-')) {
            const sign: i64 = if (text[index] == '-') -1 else 1;
            index += 1;
            const offsetHours = readDigits(text, &index, 2) orelse {
                return std.math.nan(f64);
            };
            _ = consume(text, &index, ':');
            const offsetMinutePart = readDigits(text, &index, 2) orelse {
                return std.math.nan(f64);
            };
            if (offsetHours > 23 or offsetMinutePart > 59) {
                return std.math.nan(f64);
            }
            offsetMinutes = sign * (offsetHours * 60 + offsetMinutePart);
        }
    }
    if (index != text.len) {
        return std.math.nan(f64);
    }
    if (month < 1 or month > 12 or day < 1 or day > 31 or hours > 24 or minutes > 59 or seconds > 59) {
        return std.math.nan(f64);
    }
    if (hours == 24 and (minutes != 0 or seconds != 0 or milliseconds != 0)) {
        return std.math.nan(f64);
    }
    // A day past the end of the month rolls over into the next month (JavaScriptCore accepts 2020-02-30).
    const days = daysFromCivil(year, month, 1) + day - 1;
    const time = days * 86_400_000 + hours * 3_600_000 + minutes * 60_000 + seconds * 1000 + milliseconds - offsetMinutes * 60_000;
    if (!isValidTime(time)) {
        return std.math.nan(f64);
    }
    return @floatFromInt(time);
}

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
// Returns the byte width of the JavaScript whitespace character at index (the characters String.prototype.trim
// removes: ASCII whitespace, NBSP, BOM and the line and paragraph separators), or 0 when it is not whitespace.
//
fn jsWhitespaceWidth(text: []const u8, index: usize) usize {
    const character = text[index];
    if (character == ' ' or character == '\t' or character == '\n' or character == '\r' or character == 0x0b or character == 0x0c) {
        return 1;
    }
    if (std.mem.startsWith(u8, text[index..], "\u{00A0}")) {
        return 2;
    }
    if (std.mem.startsWith(u8, text[index..], "\u{FEFF}")) {
        return 3;
    }
    if (std.mem.startsWith(u8, text[index..], "\u{2028}") or std.mem.startsWith(u8, text[index..], "\u{2029}")) {
        return 3;
    }
    return 0;
}

//
// Converts a string to a number like JavaScript's StringToNumber (`Number(string)`).
//
pub fn stringToNumber(textValue: []const u8) f64 {
    var start: usize = 0;
    var end: usize = textValue.len;
    while (start < end) {
        const width = jsWhitespaceWidth(textValue, start);
        if (width == 0) {
            break;
        }
        start += width;
    }
    while (end > start) {
        var trimmed = false;
        var back: usize = 1;
        while (back <= 3 and back <= end - start) : (back += 1) {
            if (jsWhitespaceWidth(textValue, end - back) == back) {
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
