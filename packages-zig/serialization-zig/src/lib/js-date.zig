const std = @import("std");

//
// No TypeScript counterpart: the JavaScript Date semantics the TypeScript code relies on (`new Date(string)`,
// `Date.prototype.toISOString`, `Date.prototype.toString`), as time values in milliseconds since the epoch.
// Moved here from bdb-zig's js-value.zig so the packages below bdb (tools-zig) can use them; js-value.zig
// re-exports them.
//
// Deviations from JavaScript: local time is assumed to be UTC (Date.prototype.toString and Date.parse of a
// date-time without an offset), and Date.parse only accepts the ECMAScript date time string format (ISO 8601
// subset); other formats give NaN.
//

//
// The largest absolute time value a JavaScript Date holds (8.64e15 milliseconds).
//
pub const MAX_TIME_VALUE: i64 = 8_640_000_000_000_000;

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
pub fn daysFromCivil(yearValue: i64, month: i64, day: i64) i64 {
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
// Formats a time value like `Date.prototype.toLocaleDateString()` in the en-US locale (the only locale Bun uses)
// with the local time zone assumed to be UTC (for example "5/27/2025"). Years before 1 are shown as era years
// without the era, as ICU does (year 0 is "1", year -1 is "2"). NaN or out of range times are "Invalid Date".
//
pub fn writeLocaleDateString(writer: *std.Io.Writer, time: f64) !void {
    if (std.math.isNan(time) or @abs(time) > @as(f64, @floatFromInt(MAX_TIME_VALUE))) {
        try writer.writeAll("Invalid Date");
        return;
    }
    const parts = dateParts(@intFromFloat(@trunc(time)));
    const eraYear = if (parts.year > 0) parts.year else 1 - parts.year;
    try writer.print("{d}/{d}/{d}", .{ parts.month, parts.day, eraYear });
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
