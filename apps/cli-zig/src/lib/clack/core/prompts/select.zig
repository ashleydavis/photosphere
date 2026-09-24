const std = @import("std");
const prompt_module = @import("prompt.zig");
const settings = @import("../utils/settings.zig");
const Prompt = prompt_module.Prompt;
const PromptOptions = prompt_module.PromptOptions;
const PromptOutcome = prompt_module.PromptOutcome;
const Action = settings.Action;

//
// An option of a select prompt (TypeScript: Option<Value> with a string value).
//
pub const SelectOption = struct {
    // Internal data for this option.
    value: []const u8,

    // The optional, user-facing text for this option (the value when null).
    label: ?[]const u8 = null,

    // An optional hint to display when this option is active.
    hint: ?[]const u8 = null,
};

//
// Options of a SelectPrompt.
//
pub const SelectOptions = struct {
    // The options shared by every prompt.
    base: PromptOptions,

    // The options to choose from.
    options: []const SelectOption,

    // The value of the initially selected option.
    initialValue: ?[]const u8 = null,
};

//
// A prompt that picks one of several options with the arrow keys.
//
pub const SelectPrompt = struct {
    // The base prompt.
    prompt: Prompt,

    // The options to choose from.
    options: []const SelectOption,

    // The index of the selected option.
    cursor: usize,

    // The value of the selected option.
    value: []const u8,

    //
    // The selected option.
    //
    fn _selectedValue(self: *SelectPrompt) SelectOption {
        return self.options[self.cursor];
    }

    //
    // Updates the value from the selected option.
    //
    fn changeValue(self: *SelectPrompt) void {
        self.value = self._selectedValue().value;
    }

    //
    // Creates the prompt (the prompt must not move after init). There must be at least one option.
    //
    pub fn init(self: *SelectPrompt, allocator: std.mem.Allocator, opts: SelectOptions) void {
        self.* = .{
            .prompt = Prompt.init(allocator, opts.base, false, .{ .select = self }),
            .options = opts.options,
            .cursor = 0,
            .value = "",
        };
        if (opts.initialValue) |initialValue| {
            for (self.options, 0..) |option, index| {
                if (std.mem.eql(u8, option.value, initialValue)) {
                    self.cursor = index;
                    break;
                }
            }
        }
        self.changeValue();
    }

    //
    // Handles the 'cursor' event: moves the selection (wrapping around).
    //
    pub fn onCursor(self: *SelectPrompt, key: Action) void {
        switch (key) {
            .left, .up => {
                self.cursor = if (self.cursor == 0) self.options.len - 1 else self.cursor - 1;
            },
            .down, .right => {
                self.cursor = if (self.cursor == self.options.len - 1) 0 else self.cursor + 1;
            },
            else => {},
        }
        self.changeValue();
    }

    //
    // Shows the prompt and waits for the selection.
    //
    pub fn run(self: *SelectPrompt) !PromptOutcome {
        return self.prompt.prompt();
    }
};
