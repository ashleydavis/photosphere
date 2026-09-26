const std = @import("std");
const utils = @import("utils-zig");
const console = utils.console;

test "log and debug write lines to stdout, error and warn to stderr" {
    var stdout_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr_capture.deinit();
    console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer console.setCapture(null, null);

    console.log("one");
    console.debug("two");
    console.@"error"("three");
    console.warn("four");
    console.logFormat("five {d}", .{5});
    console.errorFormat("six {s}", .{"6"});

    try std.testing.expectEqualStrings("one\ntwo\nfive 5\n", stdout_capture.written());
    try std.testing.expectEqualStrings("three\nfour\nsix 6\n", stderr_capture.written());
}
