const std = @import("std");
const cli = @import("cli-zig");
const sisteransi = cli.sisteransi;

test "cursor.move writes nothing for zero and the right sequences otherwise" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try sisteransi.cursor.move(&writer, 0, 0);
    try std.testing.expectEqualStrings("", writer.buffered());
    try sisteransi.cursor.move(&writer, -999, -3);
    try sisteransi.cursor.move(&writer, 2, 1);
    try std.testing.expectEqualStrings("\x1b[999D\x1b[3A\x1b[2C\x1b[1B", writer.buffered());
}

test "erase.lines erases upwards and returns to the first column" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try sisteransi.erase.lines(&writer, 2);
    try std.testing.expectEqualStrings("\x1b[2K\x1b[1A\x1b[2K\x1b[G", writer.buffered());
}

test "erase.down repeats the sequence" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try sisteransi.erase.down(&writer, 2);
    try std.testing.expectEqualStrings("\x1b[J\x1b[J", writer.buffered());
}
