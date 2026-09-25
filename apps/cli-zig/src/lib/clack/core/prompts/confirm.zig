const std = @import("std");
const prompt_module = @import("prompt.zig");
const sisteransi = @import("../../third-party/sisteransi.zig");
const Prompt = prompt_module.Prompt;
const PromptOptions = prompt_module.PromptOptions;
const PromptOutcome = prompt_module.PromptOutcome;

//
// Options of a ConfirmPrompt.
//
pub const ConfirmOptions = struct {
    // The options shared by every prompt.
    base: PromptOptions,

    // The label of the "yes" choice.
    active: []const u8,

    // The label of the "no" choice.
    inactive: []const u8,

    // The initially selected choice.
    initialValue: ?bool = null,
};

//
// A yes/no prompt. Left/right (and any other cursor action) toggles, y/n answer directly.
//
pub const ConfirmPrompt = struct {
    // The base prompt.
    prompt: Prompt,

    // The selected choice.
    value: bool,

    // The label of the "yes" choice.
    active: []const u8,

    // The label of the "no" choice.
    inactive: []const u8,

    //
    // The index of the selected choice: 0 for yes, 1 for no.
    //
    pub fn cursor(self: *ConfirmPrompt) usize {
        return if (self.value) 0 else 1;
    }

    //
    // The value of the choice under the cursor.
    //
    fn _value(self: *ConfirmPrompt) bool {
        return self.cursor() == 0;
    }

    //
    // Creates the prompt (the prompt must not move after init).
    //
    pub fn init(self: *ConfirmPrompt, allocator: std.mem.Allocator, opts: ConfirmOptions) void {
        self.* = .{
            .prompt = Prompt.init(allocator, opts.base, false, .{ .confirm = self }),
            .value = opts.initialValue orelse false,
            .active = opts.active,
            .inactive = opts.inactive,
        };
    }

    //
    // Handles the 'userInput' event.
    //
    pub fn onUserInput(self: *ConfirmPrompt) void {
        self.value = self._value();
    }

    //
    // Handles the 'confirm' event (y or n): submits the answer.
    //
    pub fn onConfirm(self: *ConfirmPrompt, confirmed: bool) !void {
        try sisteransi.cursor.move(self.prompt.output, 0, -1);
        self.value = confirmed;
        self.prompt.state = .submit;
        try self.prompt.close();
    }

    //
    // Handles the 'cursor' event: toggles the choice.
    //
    pub fn onCursor(self: *ConfirmPrompt) void {
        self.value = !self.value;
    }

    //
    // Shows the prompt and waits for the answer.
    //
    pub fn run(self: *ConfirmPrompt) !PromptOutcome {
        return self.prompt.prompt();
    }
};
