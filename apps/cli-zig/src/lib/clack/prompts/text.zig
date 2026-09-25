const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const prompt_module = @import("../core/prompts/prompt.zig");
const TextPrompt = core.TextPrompt;
const Prompt = core.Prompt;
const PromptResult = core.PromptResult;
const ValidateFn = prompt_module.ValidateFn;
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_BAR_END = common.S_BAR_END;
const symbol = common.symbol;

//
// Options of the text prompt.
//
pub const TextOptions = struct {
    // The streams of the prompt.
    common: CommonOptions = .{},

    // The question.
    message: []const u8,

    // Text shown when the input is empty.
    placeholder: ?[]const u8 = null,

    // The value submitted when the input is empty.
    defaultValue: ?[]const u8 = null,

    // The initial text of the input.
    initialValue: ?[]const u8 = null,

    // Validates the value on submit (returns an error message, or null when valid).
    validate: ?ValidateFn = null,
};

//
// The state of the render function of a text prompt.
//
const TextRender = struct {
    // The options of the prompt.
    opts: TextOptions,

    //
    // Renders a frame of the text prompt.
    //
    fn render(context: *anyopaque, prompt: *Prompt) anyerror!?[]const u8 {
        const self: *TextRender = @ptrCast(@alignCast(context));
        const textPrompt = prompt.kind.text;
        const allocator = prompt.allocator;
        const title = try std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ try symbol(allocator, prompt.state), self.opts.message });
        const placeholder = if (self.opts.placeholder) |placeholderText|
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ try color.inverse(allocator, placeholderText[0..@min(1, placeholderText.len)]), try color.dim(allocator, placeholderText[@min(1, placeholderText.len)..]) })
        else
            try color.inverse(allocator, try color.hidden(allocator, "_"));
        const userInput = if (prompt.userInput.len == 0) placeholder else try textPrompt.userInputWithCursor(allocator);
        const value = textPrompt.value orelse "";

        switch (prompt.state) {
            .@"error" => {
                const errorText = if (prompt.@"error".len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{try color.yellow(allocator, prompt.@"error")}) else "";
                return try std.fmt.allocPrint(allocator, "{s}\n{s}  {s}\n{s}{s}\n", .{ std.mem.trim(u8, title, " \t\n\r"), try color.yellow(allocator, S_BAR()), userInput, try color.yellow(allocator, S_BAR_END()), errorText });
            },
            .submit => {
                const valueText = if (value.len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{try color.dim(allocator, value)}) else "";
                return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ title, try color.gray(allocator, S_BAR()), valueText });
            },
            .cancel => {
                const valueText = if (value.len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{try color.strikethrough(allocator, try color.dim(allocator, value))}) else "";
                const trailer = if (std.mem.trim(u8, value, " \t\n\r").len > 0) try std.fmt.allocPrint(allocator, "\n{s}", .{try color.gray(allocator, S_BAR())}) else "";
                return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ title, try color.gray(allocator, S_BAR()), valueText, trailer });
            },
            else => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}\n{s}\n", .{ title, try color.cyan(allocator, S_BAR()), userInput, try color.cyan(allocator, S_BAR_END()) });
            },
        }
    }
};

//
// Asks for a line of text. Returns the text, or cancel.
//
pub fn text(allocator: std.mem.Allocator, io: std.Io, opts: TextOptions) !PromptResult([]const u8) {
    const renderState = try allocator.create(TextRender);
    renderState.* = .{ .opts = opts };
    const input = common.resolveInput(io, opts.common);
    input.allocator = allocator;
    const textPrompt = try allocator.create(TextPrompt);
    textPrompt.init(allocator, .{
        .base = .{
            .render = .{ .context = renderState, .function = TextRender.render },
            .validate = opts.validate,
            .input = input,
            .output = common.resolveOutput(io, opts.common),
        },
        .placeholder = opts.placeholder,
        .defaultValue = opts.defaultValue,
        .initialValue = opts.initialValue,
    });
    const outcome = try textPrompt.run();
    return switch (outcome) {
        .submit => .{ .value = textPrompt.value orelse "" },
        .cancel => .cancel,
    };
}
