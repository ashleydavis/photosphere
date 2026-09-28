const std = @import("std");
const tty = @import("../../../tty.zig");
const readline = @import("../../third-party/readline.zig");
const builtin = @import("builtin");
const sisteransi = @import("../../third-party/sisteransi.zig");
const common = @import("../../prompts/common.zig");
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

//
// Options of block().
//
pub const BlockOptions = struct {
    // The input whose keys are swallowed (process.stdin when null).
    input: ?*readline.PromptInput = null,

    // The output the cursor is hidden and moved on (process.stdout when null).
    output: ?*std.Io.Writer = null,

    // Whether each key's echo is erased.
    overwrite: bool = true,

    // Whether the cursor is hidden while blocked.
    hideCursor: bool = true,
};

//
// What block() leaves running: the thread swallowing keys, and what the unblock function needs.
//
pub const IBlock = struct {
    // The input whose keys are swallowed.
    input: *readline.PromptInput,

    // The output the cursor is hidden and moved on.
    output: *std.Io.Writer,

    // The options block was called with.
    options: BlockOptions,

    // The thread reading keys, or null when the input is not a TTY (nothing emits keypress events then).
    thread: ?std.Thread,

    // Set by unblock to stop the thread.
    stopped: std.atomic.Value(bool),

    //
    // Ends the block: stops swallowing keys, shows the cursor again and restores the terminal (the function block
    // returns in TypeScript).
    //
    pub fn unblock(self: *IBlock) !void {
        self.stopped.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.options.hideCursor) {
            try self.output.writeAll(sisteransi.cursor.show);
            try self.output.flush();
        }

        // Prevent Windows specific issues: https://github.com/bombshell-dev/clack/issues/176
        if (self.input.isTTY() and builtin.os.tag != .windows) {
            try self.input.setRawMode(false);
        }
        std.heap.smp_allocator.destroy(self);
    }

    //
    // The keypress listener (`clear`): Ctrl+C or escape ends the process, any other key's echo is erased.
    //
    fn swallowKeys(self: *IBlock) void {
        while (!self.stopped.load(.acquire)) {
            const ready = self.input.waitForInput(100) catch {
                return;
            };
            if (!ready or self.stopped.load(.acquire)) {
                continue;
            }
            const keypress = self.input.nextKeypress() catch {
                return;
            };
            const name = keypress.key.name;
            if (isActionKey(&.{ keypress.char, name, keypress.key.sequence }, .cancel)) {
                if (self.options.hideCursor) {
                    self.output.writeAll(sisteransi.cursor.show) catch {};
                    self.output.flush() catch {};
                }
                self.input.setRawMode(false) catch {};
                std.process.exit(0);
            }
            if (!self.options.overwrite) {
                continue;
            }
            const isReturn = name != null and std.mem.eql(u8, name.?, "return");
            const dx: i64 = if (isReturn) 0 else -1;
            const dy: i64 = if (isReturn) -1 else 0;
            sisteransi.cursor.move(self.output, dx, dy) catch {};
            // readline.clearLine(output, 1): clear from the cursor to the end of the line.
            self.output.writeAll("\x1b[0K") catch {};
            self.output.flush() catch {};
        }
    }
};

//
// Swallows the keys typed while something (a spinner) is drawn: switches the input to raw mode, hides the cursor
// and erases the echo of each key, until unblock is called. Ctrl+C ends the process, as in TypeScript.
//
pub fn block(io: std.Io, options: BlockOptions) !*IBlock {
    const input = options.input orelse common.resolveInput(io, .{});
    const output = options.output orelse common.resolveOutput(io, .{});
    const blocked = try std.heap.smp_allocator.create(IBlock);
    blocked.* = .{
        .input = input,
        .output = output,
        .options = options,
        .thread = null,
        .stopped = .init(false),
    };

    if (input.isTTY()) {
        try input.setRawMode(true);
    }

    if (options.hideCursor) {
        try output.writeAll(sisteransi.cursor.hide);
        try output.flush();
    }
    if (input.isTTY()) {
        blocked.thread = try std.Thread.spawn(.{}, IBlock.swallowKeys, .{blocked});
    }
    return blocked;
}

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
