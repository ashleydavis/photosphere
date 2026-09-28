const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");

const spinner = cli.spinner.spinner;

//
// Captures what the console log writes while a test runs.
//
const ICapture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,
};

//
// Starts capturing the console output.
//
fn startCapture(allocator: std.mem.Allocator) !*ICapture {
    const capture = try allocator.create(ICapture);
    capture.* = .{
        .stdout = std.Io.Writer.Allocating.init(allocator),
        .stderr = std.Io.Writer.Allocating.init(allocator),
    };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    return capture;
}

test "uses the animated spinner when a user is watching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const capture = try startCapture(allocator);
    defer utils.console.setCapture(null, null);

    const spin = try spinner(allocator, std.testing.io, true);

    // The animated spinner draws on the terminal; starting it here would draw on the test runner's stdout, so the
    // test checks which kind it is and that nothing was logged.
    try std.testing.expect(spin == .animated);
    try std.testing.expectEqualStrings("", capture.stdout.written());
}

test "does not create an animated spinner when non-interactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try startCapture(allocator);
    defer utils.console.setCapture(null, null);

    // The animated spinner takes hold of the terminal, which stops the process outright when it
    // is not the terminal's foreground job. With --yes there is nobody watching it anyway.
    const spin = try spinner(allocator, std.testing.io, false);

    try spin.start("Waiting");

    try std.testing.expect(spin == .plain);
}

test "reports the same messages as plain log lines when non-interactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const capture = try startCapture(allocator);
    defer utils.console.setCapture(null, null);
    const spin = try spinner(allocator, std.testing.io, false);

    try spin.start("Waiting for sender");
    spin.message("Still waiting");
    try spin.stop("Payload received");

    try std.testing.expectEqualStrings("Waiting for sender\nStill waiting\nPayload received\n", capture.stdout.written());
}

test "reports nothing as cancelled when non-interactive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spin = try spinner(arena.allocator(), std.testing.io, false);

    try std.testing.expect(!spin.isCancelled());
}
