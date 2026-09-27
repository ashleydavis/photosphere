const std = @import("std");
const tty = @import("../../../tty.zig");
const readline = @import("../../third-party/readline.zig");
pub const string = @import("string.zig");
pub const settings = @import("settings.zig");
pub const diffLines = string.diffLines;
pub const isActionKey = settings.isActionKey;

//
// The result of a prompt: the value, or cancel (TypeScript: the value or the `clack:cancel` symbol).
//
pub fn PromptResult(comptime T: type) type {
    return union(enum) {
        // The submitted value.
        value: T,

        // The prompt was cancelled (CANCEL_SYMBOL).
        cancel,
    };
}

//
// True when the prompt result is the cancel symbol.
//
pub fn isCancel(value: anytype) bool {
    return value == .cancel;
}

//
// Switches raw mode of the input on or off when it is a TTY.
//
pub fn setRawMode(input: *readline.PromptInput, value: bool) !void {
    if (input.isTTY()) {
        try input.setRawMode(value);
    }
}

// Not ported: block (not used by the CLI).

//
// The number of columns of process.stdout (`process.stdout.columns`), or null when stdout is not a TTY.
//
pub fn stdoutColumns() ?usize {
    return tty.columns(tty.stdout_fd);
}

//
// Gets the number of columns of the output (`getColumns`), 80 when unknown.
//
pub fn getColumns() usize {
    return stdoutColumns() orelse 80;
}
