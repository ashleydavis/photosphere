const std = @import("std");
const utils = @import("../utils/index.zig");
const types = @import("../types.zig");
const readline = @import("../../third-party/readline.zig");
const sisteransi = @import("../../third-party/sisteransi.zig");
const wrap_ansi = @import("../../third-party/wrap-ansi.zig");
const string_width = @import("../../third-party/string-width.zig");
const ClackState = types.ClackState;
const Key = readline.Key;
const PromptInput = readline.PromptInput;
const PromptOutcome = @import("prompt.zig").PromptOutcome;
const cursor = sisteransi.cursor;
const erase = sisteransi.erase;
const wrap = wrap_ansi.wrapAnsi;
const isActionKey = utils.isActionKey;
const setRawMode = utils.setRawMode;

//
// The function that renders a frame of the multiline prompt; null renders nothing.
//
pub const MultilineRenderFn = struct {
    // The state of the render function.
    context: *anyopaque,

    // Renders the frame for the prompt's current state.
    function: *const fn (context: *anyopaque, prompt: *MultilinePrompt) anyerror!?[]const u8,
};

//
// A validation function run on Ctrl+D: returns an error message, or null when the value is valid.
//
pub const MultilineValidateFn = struct {
    // The state of the validation function.
    context: ?*anyopaque,

    // Validates the value.
    function: *const fn (context: ?*anyopaque, value: []const u8) ?[]const u8,
};

//
// Options accepted by MultilinePrompt.
//
pub const MultilinePromptOptions = struct {
    //
    // Returns the frame string to render for the current state.
    //
    render: MultilineRenderFn,

    //
    // Optional validation run on Ctrl+D. Return a string or Error to block submission.
    //
    validate: ?MultilineValidateFn = null,

    //
    // Input stream (defaults to process.stdin).
    //
    input: *PromptInput,

    //
    // Output stream (defaults to process.stdout).
    //
    output: *std.Io.Writer,
};

//
// A multiline text input prompt.
// Enter adds a new line; Ctrl+D submits; Ctrl+C cancels.
//
pub const MultilinePrompt = struct {
    //
    // Allocator for lines and frames (an arena owned by the caller).
    //
    allocator: std.mem.Allocator,

    //
    // Input stream used for reading keypresses.
    //
    input: *PromptInput,

    //
    // Output stream used for rendering.
    //
    output: *std.Io.Writer,

    //
    // Lines that have been completed by pressing Enter.
    //
    completedLines: std.ArrayList([]const u8),

    //
    // The line currently being typed.
    //
    currentLine: []const u8,

    //
    // Cursor position within the current line (in bytes).
    //
    cursorPos: usize,

    //
    // Current prompt state.
    //
    state: ClackState,

    //
    // Validation error message, populated when validation fails on submit.
    //
    @"error": []const u8,

    // The validation function.
    _validate: ?MultilineValidateFn,

    // Renders the frames.
    _render: MultilineRenderFn,

    // The previously rendered frame.
    _prevFrame: []const u8,

    //
    // Creates the prompt.
    //
    pub fn init(allocator: std.mem.Allocator, opts: MultilinePromptOptions) MultilinePrompt {
        return .{
            .allocator = allocator,
            .input = opts.input,
            .output = opts.output,
            .completedLines = .empty,
            .currentLine = "",
            .cursorPos = 0,
            .state = .initial,
            .@"error" = "",
            ._validate = opts.validate,
            ._render = opts.render,
            ._prevFrame = "",
        };
    }

    //
    // Returns the full accumulated text: completed lines joined with newlines,
    // followed by the current line.
    //
    pub fn getValue(self: *MultilinePrompt) ![]const u8 {
        var all_lines: std.ArrayList([]const u8) = .empty;
        try all_lines.appendSlice(self.allocator, self.completedLines.items);
        try all_lines.append(self.allocator, self.currentLine);
        return std.mem.join(self.allocator, "\n", all_lines.items);
    }

    //
    // Handles a keypress.
    //
    fn onKeypress(self: *MultilinePrompt, char: ?[]const u8, key: Key) !void {
        if (self.state == .@"error") {
            self.state = .active;
        }

        const name = key.name orelse "";
        const is_ctrl_d = (key.ctrl and std.mem.eql(u8, name, "d")) or (char != null and std.mem.eql(u8, char.?, "\x04"));
        if (is_ctrl_d) {
            const value = try self.getValue();
            if (self._validate) |validate| {
                if (validate.function(validate.context, value)) |problem| {
                    self.@"error" = problem;
                    self.state = .@"error";
                }
                else {
                    self.state = .submit;
                }
            }
            else {
                self.state = .submit;
            }
        }
        else if (isActionKey(&.{ char, key.name, key.sequence }, .cancel)) {
            self.state = .cancel;
        }
        else if (std.mem.eql(u8, name, "return")) {
            try self.completedLines.append(self.allocator, self.currentLine);
            self.currentLine = "";
            self.cursorPos = 0;
        }
        else if (std.mem.eql(u8, name, "backspace")) {
            if (self.cursorPos > 0) {
                var start = self.cursorPos - 1;
                while (start > 0 and (self.currentLine[start] & 0xC0) == 0x80) {
                    start -= 1;
                }
                self.currentLine = try std.mem.concat(self.allocator, u8, &.{ self.currentLine[0..start], self.currentLine[self.cursorPos..] });
                self.cursorPos = start;
            }
            else if (self.completedLines.items.len > 0) {
                const prevLine = self.completedLines.pop() orelse "";
                self.cursorPos = prevLine.len;
                self.currentLine = try std.mem.concat(self.allocator, u8, &.{ prevLine, self.currentLine });
            }
        }
        else if (char != null and !key.ctrl and !key.meta and string_width.decodeAt(char.?, 0).length == char.?.len) {
            const text = char.?;
            self.currentLine = try std.mem.concat(self.allocator, u8, &.{ self.currentLine[0..self.cursorPos], text, self.currentLine[self.cursorPos..] });
            self.cursorPos += text.len;
        }

        try self.render();
    }

    //
    // Renders the current frame (the whole frame is redrawn).
    //
    fn render(self: *MultilinePrompt) !void {
        const rendered = try self._render.function(self._render.context, self);
        const frame = try wrap(self.allocator, rendered orelse "", utils.stdoutColumns());
        if (std.mem.eql(u8, frame, self._prevFrame)) {
            return;
        }

        if (self.state == .initial) {
            try self.output.writeAll(cursor.hide);
        }
        else {
            const previous = try wrap(self.allocator, self._prevFrame, utils.stdoutColumns());
            const prevLineCount = std.mem.count(u8, previous, "\n");
            try cursor.move(self.output, -999, -@as(i64, @intCast(prevLineCount)));
            try erase.down(self.output, 1);
        }

        try self.output.writeAll(frame);

        if (self.state == .initial) {
            self.state = .active;
        }

        self._prevFrame = frame;
        try self.output.flush();
    }

    //
    // Restores the terminal after the prompt finishes.
    //
    fn close(self: *MultilinePrompt) !void {
        try self.output.writeAll(cursor.show);
        try self.output.writeAll("\n");
        setRawMode(self.input, false);
        try self.output.flush();
    }

    //
    // Displays the prompt and returns submit with the entered text (getValue), or cancel if the user
    // cancels.
    //
    pub fn prompt(self: *MultilinePrompt) !PromptOutcome {
        // Not ported: the AbortSignal option (not used by the CLI).
        setRawMode(self.input, true);

        // Not ported: re-rendering on terminal resize.
        try self.render();

        while (true) {
            try self.output.flush();
            const keypress = try self.input.nextKeypress();
            try self.onKeypress(keypress.char, keypress.key);
            if (self.state == .submit) {
                try self.close();
                // The keys left in the chunk that finished the prompt are lost (nothing listens for them any more).
                self.input.discardChunk();
                return .submit;
            }
            else if (self.state == .cancel) {
                try self.close();
                self.input.discardChunk();
                return .cancel;
            }
        }
    }
};
