const std = @import("std");
const prompt_module = @import("prompt.zig");
const picocolors = @import("../../../picocolors.zig");
const string_width = @import("../../third-party/string-width.zig");
const Prompt = prompt_module.Prompt;
const PromptOptions = prompt_module.PromptOptions;
const PromptOutcome = prompt_module.PromptOutcome;

//
// Options of a PasswordPrompt.
//
pub const PasswordOptions = struct {
    // The options shared by every prompt.
    base: PromptOptions,

    // The character shown for each typed character.
    mask: ?[]const u8 = null,
};

//
// A text input prompt that masks what is typed.
//
pub const PasswordPrompt = struct {
    // The base prompt.
    prompt: Prompt,

    // The value (null stands for undefined).
    value: ?[]const u8,

    // The character shown for each typed character.
    _mask: []const u8,

    //
    // The cursor position in the user input.
    //
    pub fn cursor(self: *PasswordPrompt) usize {
        return self.prompt._cursor;
    }

    //
    // The number of characters (code points) in text.
    //
    fn characterCount(text: []const u8) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            index += string_width.decodeAt(text, index).length;
            count += 1;
        }
        return count;
    }

    //
    // The user input with every character replaced by the mask.
    //
    pub fn masked(self: *PasswordPrompt, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        var count = characterCount(self.prompt.userInput);
        while (count > 0) {
            try result.appendSlice(allocator, self._mask);
            count -= 1;
        }
        return result.items;
    }

    //
    // The masked input with the cursor drawn.
    //
    pub fn userInputWithCursor(self: *PasswordPrompt, allocator: std.mem.Allocator) ![]const u8 {
        if (self.prompt.state == .submit or self.prompt.state == .cancel) {
            return self.masked(allocator);
        }
        const userInput = self.prompt.userInput;
        if (self.cursor() >= userInput.len) {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ try self.masked(allocator), try picocolors.inverse(allocator, try picocolors.hidden(allocator, "_")) });
        }
        const maskedText = try self.masked(allocator);
        const mask_offset = characterCount(userInput[0..self.cursor()]) * self._mask.len;
        const s1 = maskedText[0..mask_offset];
        const s2 = maskedText[mask_offset..];
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ s1, try picocolors.inverse(allocator, s2[0..self._mask.len]), s2[self._mask.len..] });
    }

    //
    // Creates the prompt (the prompt must not move after init).
    //
    pub fn init(self: *PasswordPrompt, allocator: std.mem.Allocator, opts: PasswordOptions) void {
        self.* = .{
            .prompt = Prompt.init(allocator, opts.base, true, .{ .password = self }),
            .value = null,
            ._mask = opts.mask orelse "\u{2022}",
        };
    }

    //
    // Handles the 'userInput' event: the value follows the input.
    //
    pub fn onUserInput(self: *PasswordPrompt, input: []const u8) void {
        self.value = input;
    }

    //
    // Shows the prompt and waits for the input.
    //
    pub fn run(self: *PasswordPrompt) !PromptOutcome {
        return self.prompt.prompt();
    }
};
