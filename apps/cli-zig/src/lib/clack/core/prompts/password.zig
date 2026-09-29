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
    // The text with each UTF-16 code unit replaced by the mask, one piece per code unit
    // (`text.replaceAll(/./g, mask)`): a character outside the Basic Multilingual Plane is two code units, and `.`
    // does not match a line terminator (\n, \r, U+2028, U+2029), which is kept.
    //
    fn maskedUnits(self: *PasswordPrompt, allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
        var pieces: std.ArrayList([]const u8) = .empty;
        var index: usize = 0;
        while (index < text.len) {
            const decoded = string_width.decodeAt(text, index);
            const codePoint = decoded.codePoint;
            if (codePoint == '\n' or codePoint == '\r' or codePoint == 0x2028 or codePoint == 0x2029) {
                try pieces.append(allocator, text[index .. index + decoded.length]);
            }
            else {
                try pieces.append(allocator, self._mask);
                if (codePoint > 0xFFFF) {
                    try pieces.append(allocator, self._mask);
                }
            }
            index += decoded.length;
        }
        return pieces.items;
    }

    //
    // The user input with every character replaced by the mask.
    //
    pub fn masked(self: *PasswordPrompt, allocator: std.mem.Allocator) ![]const u8 {
        return std.mem.concat(allocator, u8, try self.maskedUnits(allocator, self.prompt.userInput));
    }

    //
    // The masked input with the cursor drawn. The cursor counts the UTF-16 code units of the input before it, and
    // `s2[0]` is the first code unit of the rest, which is one piece because both masks are one code unit.
    //
    pub fn userInputWithCursor(self: *PasswordPrompt, allocator: std.mem.Allocator) ![]const u8 {
        if (self.prompt.state == .submit or self.prompt.state == .cancel) {
            return self.masked(allocator);
        }
        const userInput = self.prompt.userInput;
        if (self.cursor() >= userInput.len) {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ try self.masked(allocator), try picocolors.inverse(allocator, try picocolors.hidden(allocator, "_")) });
        }
        const pieces = try self.maskedUnits(allocator, userInput);
        const unitsBefore = (try self.maskedUnits(allocator, userInput[0..self.cursor()])).len;
        const s1 = try std.mem.concat(allocator, u8, pieces[0..unitsBefore]);
        const rest = try std.mem.concat(allocator, u8, pieces[unitsBefore + 1 ..]);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ s1, try picocolors.inverse(allocator, pieces[unitsBefore]), rest });
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
