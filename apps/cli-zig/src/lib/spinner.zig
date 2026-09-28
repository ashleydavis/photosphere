const std = @import("std");
const utils = @import("utils-zig");
const prompts = @import("clack/prompts.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const log = &utils.log.log;
const clackSpinner = prompts.spinner;

//
// Something to report the progress of a long wait with (TypeScript: SpinnerResult): the animated clack spinner, or
// plain log lines.
//
pub const SpinnerResult = union(enum) {
    // The animated spinner, for a run someone is watching.
    animated: *prompts.Spinner,

    // Plain log lines, for a non-interactive run.
    plain,

    //
    // Starts reporting with a message.
    //
    pub fn start(self: SpinnerResult, text: []const u8) !void {
        switch (self) {
            .animated => |animated| try animated.start(text),
            .plain => log.info(text),
        }
    }

    //
    // Stops reporting with a final message.
    //
    pub fn stop(self: SpinnerResult, text: []const u8) !void {
        switch (self) {
            .animated => |animated| try animated.stop(text, 0),
            .plain => log.info(text),
        }
    }

    //
    // Changes the message.
    //
    pub fn message(self: SpinnerResult, text: []const u8) void {
        switch (self) {
            .animated => |animated| animated.message(text),
            .plain => log.info(text),
        }
    }

    //
    // True when a signal cancelled the animated spinner.
    //
    // The animated spinner sets this when a signal arrives mid-spin, which it can only know
    // about because it is the thing holding the terminal. The plain lines hold nothing, and every
    // caller installs its own SIGINT handler, so there is nothing for them to report.
    //
    pub fn isCancelled(self: SpinnerResult) bool {
        return switch (self) {
            .animated => |animated| animated.isCancelled(),
            .plain => false,
        };
    }
};

//
// Returns something to report the progress of a long wait with, matched to whether anyone is
// watching it happen.
//
// An interactive run gets the animated spinner. A non-interactive run (`--yes`) gets plain log lines
// saying the same things, because the spinner is not just decoration: it takes hold of the terminal
// to swallow the keystrokes of the person watching it, and switching the terminal into raw mode from
// outside its foreground process group is a thing the kernel stops a process for. Nothing resumes it.
//
// That is not hypothetical. Every CLI smoke test runs under `timeout`, which puts it in a process
// group of its own, so `psi dbs send --yes` started spinning and froze on the spot, silent, until the
// suite's 300 second timeout killed it. It only happened with a terminal attached, so the git hook
// and CI never saw it.
//
// Usage: spinner(allocator, io, !skipPrompts)
//
pub fn spinner(allocator: std.mem.Allocator, io: std.Io, interactive: bool) !SpinnerResult {
    if (interactive) {
        return .{ .animated = try clackSpinner(allocator, io, .{}) };
    }

    return .plain;
}
