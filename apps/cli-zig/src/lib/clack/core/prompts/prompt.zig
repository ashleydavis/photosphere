const std = @import("std");
const utils = @import("../utils/index.zig");
const types = @import("../types.zig");
const readline = @import("../../third-party/readline.zig");
const sisteransi = @import("../../third-party/sisteransi.zig");
const wrap_ansi = @import("../../third-party/wrap-ansi.zig");
const confirm_prompt = @import("confirm.zig");
const select_prompt = @import("select.zig");
const text_prompt = @import("text.zig");
const password_prompt = @import("password.zig");
const ClackState = types.ClackState;
const Action = utils.settings.Action;
const Key = readline.Key;
const PromptInput = readline.PromptInput;
const cursor = sisteransi.cursor;
const erase = sisteransi.erase;
const wrap = wrap_ansi.wrapAnsi;
const diffLines = utils.diffLines;
const isActionKey = utils.isActionKey;
const setRawMode = utils.setRawMode;
const settings = utils.settings;

//
// The function that renders a frame of the prompt (TypeScript: `render(this)`); null renders nothing.
//
pub const RenderFn = struct {
    // The state of the render function.
    context: *anyopaque,

    // Renders the frame for the prompt's current state.
    function: *const fn (context: *anyopaque, prompt: *Prompt) anyerror!?[]const u8,
};

//
// A validation function: returns an error message, or null when the value is valid.
//
pub const ValidateFn = struct {
    // The state of the validation function.
    context: ?*anyopaque,

    // Validates the value (null stands for undefined).
    function: *const fn (context: ?*anyopaque, value: ?[]const u8) ?[]const u8,

    //
    // Validates the value.
    //
    pub fn call(self: ValidateFn, value: ?[]const u8) ?[]const u8 {
        return self.function(self.context, value);
    }
};

//
// Options shared by every prompt (TypeScript: PromptOptions).
//
pub const PromptOptions = struct {
    // Renders the frames of the prompt.
    render: RenderFn,

    // Text typed into the prompt before the user types (text prompts).
    initialUserInput: ?[]const u8 = null,

    // Validates the value on submit.
    validate: ?ValidateFn = null,

    // The input stream (process.stdin when created by the prompts module).
    input: *PromptInput,

    // The output stream (process.stdout when created by the prompts module).
    output: *std.Io.Writer,
};

//
// The concrete prompt that receives the events of the base prompt (the TypeScript subclass).
//
pub const PromptKind = union(enum) {
    // A ConfirmPrompt.
    confirm: *confirm_prompt.ConfirmPrompt,

    // A SelectPrompt.
    select: *select_prompt.SelectPrompt,

    // A TextPrompt.
    text: *text_prompt.TextPrompt,

    // A PasswordPrompt.
    password: *password_prompt.PasswordPrompt,
};

//
// How the prompt finished (TypeScript: the promise resolves with the value or CANCEL_SYMBOL).
//
pub const PromptOutcome = enum {
    // The value was submitted.
    submit,

    // The prompt was cancelled.
    cancel,
};

//
// The base of every prompt: reads keys, keeps the state and renders frames.
// TypeScript subscribes event handlers; in Zig the events are dispatched to the concrete prompt (`kind`).
//
pub const Prompt = struct {
    // Allocator for frames and input (an arena owned by the caller).
    allocator: std.mem.Allocator,

    // The input stream.
    input: *PromptInput,

    // The output stream.
    output: *std.Io.Writer,

    // The options that are not the render function or the streams.
    opts: PromptOptions,

    // Renders the frames.
    _render: RenderFn,

    // True when the prompt tracks the text typed into the readline interface.
    _track: bool,

    // The previously rendered frame.
    _prevFrame: []const u8,

    // The cursor position in the user input.
    _cursor: usize,

    // The readline interface (null before prompt and after close).
    rl: ?readline.Interface,

    // True while event handlers are subscribed (cleared by unsubscribe).
    subscribed: bool,

    // True once prompt() has subscribed its submit and cancel handlers.
    resolveSubscribed: bool,

    // How the prompt finished, set by the submit or cancel handler (the promise resolution).
    outcome: ?PromptOutcome,

    // The concrete prompt.
    kind: PromptKind,

    // The state of the prompt.
    state: ClackState,

    // The validation error message.
    @"error": []const u8,

    // The text typed by the user.
    userInput: []const u8,

    //
    // Creates the base prompt (TypeScript: constructor(options, trackValue = true)).
    //
    pub fn init(allocator: std.mem.Allocator, options: PromptOptions, trackValue: bool, kind: PromptKind) Prompt {
        return .{
            .allocator = allocator,
            .input = options.input,
            .output = options.output,
            .opts = options,
            ._render = options.render,
            ._track = trackValue,
            ._prevFrame = "",
            ._cursor = 0,
            .rl = null,
            .subscribed = true,
            .resolveSubscribed = false,
            .outcome = null,
            .kind = kind,
            .state = .initial,
            .@"error" = "",
            .userInput = "",
        };
    }

    //
    // Unsubscribe all listeners
    //
    fn unsubscribe(self: *Prompt) void {
        self.subscribed = false;
        self.resolveSubscribed = false;
    }

    //
    // Emits the 'userInput' event.
    //
    fn emitUserInput(self: *Prompt) void {
        if (!self.subscribed) {
            return;
        }
        switch (self.kind) {
            .confirm => |concrete| concrete.onUserInput(),
            .text => |concrete| concrete.onUserInput(self.userInput),
            .password => |concrete| concrete.onUserInput(self.userInput),
            .select => {},
        }
    }

    //
    // Emits the 'cursor' event.
    //
    fn emitCursor(self: *Prompt, action: Action) void {
        if (!self.subscribed) {
            return;
        }
        switch (self.kind) {
            .confirm => |concrete| concrete.onCursor(),
            .select => |concrete| concrete.onCursor(action),
            .text, .password => {},
        }
    }

    //
    // Emits the 'confirm' event.
    //
    fn emitConfirm(self: *Prompt, value: bool) !void {
        if (!self.subscribed) {
            return;
        }
        switch (self.kind) {
            .confirm => |concrete| try concrete.onConfirm(value),
            .select, .text, .password => {},
        }
    }

    //
    // Emits the 'finalize' event.
    //
    fn emitFinalize(self: *Prompt) void {
        if (!self.subscribed) {
            return;
        }
        switch (self.kind) {
            .text => |concrete| concrete.onFinalize(),
            .confirm, .select, .password => {},
        }
    }

    //
    // Emits the event named after the state ('submit' or 'cancel' resolve the prompt).
    //
    fn emitState(self: *Prompt) !void {
        if (!self.resolveSubscribed) {
            return;
        }
        if (self.state == .submit or self.state == .cancel) {
            try self.output.writeAll(cursor.show);
            setRawMode(self.input, false);
            self.outcome = if (self.state == .submit) .submit else .cancel;
        }
    }

    //
    // The value passed to the validation function (text and password prompts have string values).
    //
    fn validationValue(self: *Prompt) ?[]const u8 {
        return switch (self.kind) {
            .text => |concrete| concrete.value,
            .password => |concrete| concrete.value,
            .confirm, .select => null,
        };
    }

    //
    // Shows the prompt and reads keys until it is submitted or cancelled.
    //
    pub fn prompt(self: *Prompt) !PromptOutcome {
        // Not ported: the AbortSignal option (not used by the CLI).
        self.rl = readline.Interface.init(self.allocator);

        if (self.opts.initialUserInput) |initialUserInput| {
            try self._setUserInput(initialUserInput, true);
        }

        setRawMode(self.input, true);
        // Not ported: re-rendering on terminal resize.

        try self.render();

        self.resolveSubscribed = true;

        while (self.outcome == null) {
            try self.output.flush();
            const keypress = try self.input.nextKeypress();
            try self.onKeypress(keypress.char, keypress.key);
        }
        // The keys left in the chunk that finished the prompt are lost (nothing listens for them any more).
        self.input.discardChunk();
        try self.output.flush();
        return self.outcome.?;
    }

    //
    // True for keys that act on the prompt instead of being typed (only tab).
    //
    fn _isActionKey(self: *Prompt, char: ?[]const u8, key: Key) bool {
        _ = self;
        _ = key;
        if (char) |text| {
            return std.mem.eql(u8, text, "\t");
        }
        return false;
    }

    //
    // Sets the user input, optionally typing it into the readline interface.
    //
    pub fn _setUserInput(self: *Prompt, value: ?[]const u8, write: bool) !void {
        self.userInput = try self.allocator.dupe(u8, value orelse "");
        self.emitUserInput();
        if (write and self._track) {
            if (self.rl) |*interface| {
                try interface.write(self.userInput, null);
                self._cursor = interface.cursor;
            }
        }
    }

    //
    // Handles a keypress. The readline interface handles it first (it subscribed to keypresses first).
    //
    fn onKeypress(self: *Prompt, char: ?[]const u8, key: Key) !void {
        if (self.rl) |*interface| {
            try interface.ttyWrite(char, key);
        }

        const key_is_return = if (key.name) |name| std.mem.eql(u8, name, "return") else false;
        if (self._track and !key_is_return) {
            if (key.name != null and self._isActionKey(char, key)) {
                if (self.rl) |*interface| {
                    try interface.write(null, .{ .sequence = "", .name = "h", .ctrl = true, .meta = false, .shift = false });
                }
            }
            self._cursor = if (self.rl) |interface| interface.cursor else 0;
            try self._setUserInput(if (self.rl) |interface| interface.line.items else null, false);
        }

        if (self.state == .@"error") {
            self.state = .active;
        }
        if (key.name) |name| {
            if (!self._track) {
                if (settings.aliasAction(name)) |action| {
                    self.emitCursor(action);
                }
            }
            if (settings.actionNamed(name)) |action| {
                self.emitCursor(action);
            }
        }
        if (char) |text| {
            if (text.len == 1 and (std.ascii.toLower(text[0]) == 'y' or std.ascii.toLower(text[0]) == 'n')) {
                try self.emitConfirm(std.ascii.toLower(text[0]) == 'y');
            }
        }

        // Not ported: the 'key' event (no prompt used by the CLI subscribes to it).

        if (key_is_return) {
            if (self.opts.validate) |validate| {
                if (validate.call(self.validationValue())) |problem| {
                    self.@"error" = problem;
                    self.state = .@"error";
                    if (self.rl) |*interface| {
                        try interface.write(self.userInput, null);
                    }
                }
            }
            if (self.state != .@"error") {
                self.state = .submit;
            }
        }

        if (isActionKey(&.{ char, key.name, key.sequence }, .cancel)) {
            self.state = .cancel;
        }

        if (self.state == .submit or self.state == .cancel) {
            self.emitFinalize();
        }
        try self.render();
        if (self.state == .submit or self.state == .cancel) {
            try self.close();
        }
    }

    //
    // Closes the prompt: ends the line, restores the terminal and resolves the prompt.
    //
    pub fn close(self: *Prompt) !void {
        try self.output.writeAll("\n");
        setRawMode(self.input, false);
        if (self.rl) |*interface| {
            interface.close();
        }
        self.rl = null;
        try self.emitState();
        self.unsubscribe();
        try self.output.flush();
    }

    //
    // Moves the cursor back to the start of the previous frame.
    //
    fn restoreCursor(self: *Prompt) !void {
        const wrapped = try wrap(self.allocator, self._prevFrame, utils.stdoutColumns());
        const lines = std.mem.count(u8, wrapped, "\n");
        try cursor.move(self.output, -999, -@as(i64, @intCast(lines)));
    }

    //
    // Renders the current frame, redrawing only the lines that changed.
    //
    fn render(self: *Prompt) !void {
        const rendered = try self._render.function(self._render.context, self);
        const frame = try wrap(self.allocator, rendered orelse "", utils.stdoutColumns());
        if (std.mem.eql(u8, frame, self._prevFrame)) {
            return;
        }

        if (self.state == .initial) {
            try self.output.writeAll(cursor.hide);
        }
        else {
            const diff = try diffLines(self.allocator, self._prevFrame, frame);
            try self.restoreCursor();
            // If a single line has changed, only update that line
            if (diff != null and diff.?.len == 1) {
                const diffLine = diff.?[0];
                try cursor.move(self.output, 0, @intCast(diffLine));
                try erase.lines(self.output, 1);
                var lines: std.ArrayList([]const u8) = .empty;
                var line_iterator = std.mem.splitScalar(u8, frame, '\n');
                while (line_iterator.next()) |line| {
                    try lines.append(self.allocator, line);
                }
                try self.output.writeAll(lines.items[diffLine]);
                self._prevFrame = frame;
                try cursor.move(self.output, 0, @as(i64, @intCast(lines.items.len)) - @as(i64, @intCast(diffLine)) - 1);
                try self.output.flush();
                return;
                // If many lines have changed, rerender everything past the first line
            }
            if (diff != null and diff.?.len > 1) {
                const diffLine = diff.?[0];
                try cursor.move(self.output, 0, @intCast(diffLine));
                try erase.down(self.output, 1);
                var line_iterator = std.mem.splitScalar(u8, frame, '\n');
                var line_index: usize = 0;
                var first = true;
                while (line_iterator.next()) |line| {
                    if (line_index >= diffLine) {
                        if (!first) {
                            try self.output.writeAll("\n");
                        }
                        try self.output.writeAll(line);
                        first = false;
                    }
                    line_index += 1;
                }
                self._prevFrame = frame;
                try self.output.flush();
                return;
            }

            try erase.down(self.output, 1);
        }

        try self.output.writeAll(frame);
        if (self.state == .initial) {
            self.state = .active;
        }
        self._prevFrame = frame;
        try self.output.flush();
    }
};
