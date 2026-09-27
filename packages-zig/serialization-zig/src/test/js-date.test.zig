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
