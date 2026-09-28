const std = @import("std");
const cli = @import("cli-zig");

const prompts = cli.prompts;

//
// The clack spinner has no TypeScript tests (it is part of the vendored @clack/prompts). These check the port against
// the TypeScript source: what start, the animation and stop write.
//

test "the spinner hides the cursor, animates its frames and ends with the submit symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var output = std.Io.Writer.Allocating.init(allocator);
    const input = try @import("test-helpers.zig").chunkedInput(allocator, &.{});

    const spin = try prompts.spinner(allocator, std.testing.io, .{
        .common = .{
            .input = input,
            .output = &output.writer,
        },
        .frames = &.{ "A", "B" },
        .delay = 10,
    });
    try spin.start("Waiting...");
    while (std.mem.indexOf(u8, output.written(), "B  Waiting") == null) {
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    try spin.stop("Done", 0);

    const written = output.written();
    // start: the cursor is hidden (block), then the bar. The trailing dots of the message are dropped.
    try std.testing.expect(std.mem.startsWith(u8, written, "\x1b[?25l \n"));
    // The first frame, then the second after erasing the first.
    try std.testing.expect(std.mem.indexOf(u8, written, "A  Waiting") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "A  Waiting\x1b[999D\x1b[JB  Waiting") != null);
    // stop: the submit symbol and the message, then the cursor is shown again (unblock).
    const ending = try std.fmt.allocPrint(allocator, "{s}  Done\n\x1b[?25h", .{prompts.common.S_STEP_SUBMIT()});
    try std.testing.expect(std.mem.endsWith(u8, written, ending));
    try std.testing.expect(!spin.isCancelled());
}

test "the spinner stops with the cancel symbol for code 1 and the error symbol otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    const input = try @import("test-helpers.zig").chunkedInput(allocator, &.{});

    for ([_]u8{ 1, 2 }) |code| {
        var output = std.Io.Writer.Allocating.init(allocator);
        const spin = try prompts.spinner(allocator, std.testing.io, .{
            .common = .{
                .input = input,
                .output = &output.writer,
            },
            .delay = 1000,
        });
        try spin.start("Working");
        try spin.stop("Stopped", code);
        const symbol = if (code == 1) prompts.common.S_STEP_CANCEL() else prompts.common.S_STEP_ERROR();
        try std.testing.expect(std.mem.endsWith(u8, output.written(), try std.fmt.allocPrint(allocator, "{s}  Stopped\n\x1b[?25h", .{symbol})));
    }
}
