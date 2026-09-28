const std = @import("std");
const serialization = @import("serialization-zig");

const js_date = serialization.js_date;

//
// Formats a time value with writeLocaleDateString.
//
fn localeDateString(buffer: []u8, time: f64) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try js_date.writeLocaleDateString(&writer, time);
    return writer.buffered();
}

test "writeLocaleDateString matches toLocaleDateString in the en-US locale with UTC local time" {
    var buffer: [64]u8 = undefined;

    // The values Bun prints for `new Date(text).toLocaleDateString()` with TZ=UTC.
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "1970-01-01T00:00:00.000Z", .expected = "1/1/1970" },
        .{ .text = "2025-05-27T12:34:56Z", .expected = "5/27/2025" },
        .{ .text = "2023-05-01T02:00:00Z", .expected = "5/1/2023" },
        .{ .text = "0099-01-01T00:00:00Z", .expected = "1/1/99" },
        .{ .text = "0000-01-01T00:00:00Z", .expected = "1/1/1" },
        .{ .text = "0001-12-31T23:59:59Z", .expected = "12/31/1" },
        .{ .text = "9999-12-31T23:59:59Z", .expected = "12/31/9999" },
        .{ .text = "-000001-06-15T00:00:00Z", .expected = "6/15/2" },
        .{ .text = "-000100-01-01T00:00:00Z", .expected = "1/1/101" },
        .{ .text = "+012345-01-01T00:00:00Z", .expected = "1/1/12345" },
        .{ .text = "+275760-09-13T00:00:00Z", .expected = "9/13/275760" },
        .{ .text = "x", .expected = "Invalid Date" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try localeDateString(&buffer, js_date.parseDate(case.text)));
    }

    // `new Date(8.64e15 + 1)` is an invalid date.
    try std.testing.expectEqualStrings("Invalid Date", try localeDateString(&buffer, 8.64e15 + 1));
}

//
// A time value and the text a Date of it gives, as Bun prints it with TZ=UTC.
//
const IDateText = struct {
    // The time value, in milliseconds since the epoch.
    time: i64,

    // The text.
    expected: []const u8,
};

test "writeIsoString matches toISOString, with the expanded year outside 0 to 9999" {
    var buffer: [64]u8 = undefined;
    const cases = [_]IDateText{
        .{ .time = 0, .expected = "1970-01-01T00:00:00.000Z" },
        .{ .time = 1748349296789, .expected = "2025-05-27T12:34:56.789Z" },
        .{ .time = -62184499200000, .expected = "-000001-06-15T00:00:00.000Z" },
        .{ .time = 253402300800000, .expected = "+010000-01-01T00:00:00.000Z" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try js_date.writeIsoString(&writer, case.time);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "writeDateString matches toString with UTC local time" {
    var buffer: [128]u8 = undefined;
    const cases = [_]IDateText{
        .{ .time = 0, .expected = "Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)" },
        .{ .time = 1748349296789, .expected = "Tue May 27 2025 12:34:56 GMT+0000 (Coordinated Universal Time)" },
        .{ .time = -62184499200000, .expected = "Tue Jun 15 -0001 00:00:00 GMT+0000 (Coordinated Universal Time)" },
        .{ .time = -62003991233000, .expected = "Fri Mar 04 0005 05:06:07 GMT+0000 (Coordinated Universal Time)" },
        .{ .time = 253402300800000, .expected = "Sat Jan 01 10000 00:00:00 GMT+0000 (Coordinated Universal Time)" },
        .{ .time = js_date.MAX_TIME_VALUE + 1, .expected = "Invalid Date" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try js_date.writeDateString(&writer, case.time);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "parseDate reads a time zone offset like Date.parse" {
    try std.testing.expectEqual(@as(f64, 1577853000000), js_date.parseDate("2020-01-01T10:00+05:30"));
    try std.testing.expectEqual(@as(f64, 1577853000000), js_date.parseDate("2020-01-01T10:00+0530"));
    try std.testing.expectEqual(@as(f64, 1577877300000), js_date.parseDate("2020-01-01T10:00:00-01:15"));
    try std.testing.expect(std.math.isNan(js_date.parseDate("2020-01-01T10:00+24:00")));
    try std.testing.expect(std.math.isNan(js_date.parseDate("2020-01-01T10:00+05:60")));
    try std.testing.expect(std.math.isNan(js_date.parseDate("2020-01-01T10:00+05")));
    try std.testing.expect(std.math.isNan(js_date.parseDate("2020-01-01T10:00+5")));
    try std.testing.expect(std.math.isNan(js_date.parseDate("2020-0a")));
}
