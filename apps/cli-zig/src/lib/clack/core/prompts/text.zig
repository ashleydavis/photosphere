const std = @import("std");
const prompt_module = @import("prompt.zig");
const picocolors = @import("../../../picocolors.zig");
const string_width = @import("../../third-party/string-width.zig");
const Prompt = prompt_module.Prompt;
const PromptOptions = prompt_module.PromptOptions;
const PromptOutcome = prompt_module.PromptOutcome;

//
// Options of a TextPrompt.
//
pub const TextOptions = struct {
    // The options shared by every prompt.
    base: PromptOptions,

    // Text shown when the input is empty.
    placeholder: ?[]const u8 = null,

    // The value submitted when the input is empty.
    defaultValue: ?[]const u8 = null,

    // The initial text of the input.
    initialValue: ?[]const u8 = null,
};

//
// A single line text input prompt.
//
pub const TextPrompt = struct {
    // The base prompt.
    prompt: Prompt,

    // The value (null stands for undefined).
    value: ?[]const u8,

    // The value submitted when the input is empty.
    defaultValue: ?[]const u8,

    //
    // The user input with the cursor drawn (a block at the end, or the character under it inverted).
    //
    pub fn userInputWithCursor(self: *TextPrompt, allocator: std.mem.Allocator) ![]const u8 {
        if (self.prompt.state == .submit) {
            return self.prompt.userInput;
        }
        const userInput = self.prompt.userInput;
        if (self.cursor() >= userInput.len) {
            return std.fmt.allocPrint(allocator, "{s}\u{2588}", .{userInput});
        }
        const s1 = userInput[0..self.cursor()];
        const s2_length = string_width.decodeAt(userInput, self.cursor()).length;
        const s2 = userInput[self.cursor() .. self.cursor() + s2_length];
        const s3 = userInput[self.cursor() + s2_length ..];
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ s1, try picocolors.inverse(allocator, s2), s3 });
    }

    //
    // The cursor position in the user input.
    //
    pub fn cursor(self: *TextPrompt) usize {
        return self.prompt._cursor;
    }

    //
    // Creates the prompt (the prompt must not move after init).
    //
    pub fn init(self: *TextPrompt, allocator: std.mem.Allocator, opts: TextOptions) void {
        var base = opts.base;
        base.initialUserInput = opts.base.initialUserInput orelse opts.initialValue;
        self.* = .{
            .prompt = Prompt.init(allocator, base, true, .{ .text = self }),
            .value = null,
            .defaultValue = opts.defaultValue,
        };
    }

    //
    // Handles the 'userInput' event: the value follows the input.
    //
    pub fn onUserInput(self: *TextPrompt, input: []const u8) void {
        self.value = input;
    }

    //
    // Handles the 'finalize' event: an empty value becomes the default value (or "").
    //
    pub fn onFinalize(self: *TextPrompt) void {
        const is_empty = if (self.value) |text| text.len == 0 else true;
        if (is_empty) {
            self.value = self.defaultValue;
        }
        if (self.value == null) {
            self.value = "";
        }
    }

    //
    // Shows the prompt and waits for the input.
    //
    pub fn run(self: *TextPrompt) !PromptOutcome {
        return self.prompt.prompt();
    }
};
