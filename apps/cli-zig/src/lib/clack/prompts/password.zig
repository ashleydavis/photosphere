const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const prompt_module = @import("../core/prompts/prompt.zig");
const PasswordPrompt = core.PasswordPrompt;
const Prompt = core.Prompt;
const PromptResult = core.PromptResult;
const ValidateFn = prompt_module.ValidateFn;
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_BAR_END = common.S_BAR_END;
const S_PASSWORD_MASK = common.S_PASSWORD_MASK;
const symbol = common.symbol;

//
// Options of the password prompt.
//
pub const PasswordOptions = struct {
    // The streams of the prompt.
    common: CommonOptions = .{},

    // The question.
    message: []const u8,

    // The character shown for each typed character (default S_PASSWORD_MASK).
    mask: ?[]const u8 = null,

    // Validates the value on submit (returns an error message, or null when valid).
    validate: ?ValidateFn = null,
};

//
// The state of the render function of a password prompt.
//
const PasswordRender = struct {
    // The options of the prompt.
    opts: PasswordOptions,

    //
    // Renders a frame of the password prompt.
    //
    fn render(context: *anyopaque, prompt: *Prompt) anyerror!?[]const u8 {
        const self: *PasswordRender = @ptrCast(@alignCast(context));
        const passwordPrompt = prompt.kind.password;
        const allocator = prompt.allocator;
        const title = try std.fmt.allocPrint(allocator, "{s}\n{s}  {s}\n", .{ try color.gray(allocator, S_BAR()), try symbol(allocator, prompt.state), self.opts.message });
        const userInput = try passwordPrompt.userInputWithCursor(allocator);
        const masked = try passwordPrompt.masked(allocator);

        switch (prompt.state) {
            .@"error" => {
                const maskedText = if (masked.len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{masked}) else "";
                return try std.fmt.allocPrint(allocator, "{s}\n{s}{s}\n{s}  {s}\n", .{ std.mem.trim(u8, title, " \t\n\r"), try color.yellow(allocator, S_BAR()), maskedText, try color.yellow(allocator, S_BAR_END()), try color.yellow(allocator, prompt.@"error") });
            },
            .submit => {
                const maskedText = if (masked.len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{try color.dim(allocator, masked)}) else "";
                return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ title, try color.gray(allocator, S_BAR()), maskedText });
            },
            .cancel => {
                const maskedText = if (masked.len > 0) try std.fmt.allocPrint(allocator, "  {s}", .{try color.strikethrough(allocator, try color.dim(allocator, masked))}) else "";
                const trailer = if (masked.len > 0) try std.fmt.allocPrint(allocator, "\n{s}", .{try color.gray(allocator, S_BAR())}) else "";
                return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ title, try color.gray(allocator, S_BAR()), maskedText, trailer });
            },
            else => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}\n{s}\n", .{ title, try color.cyan(allocator, S_BAR()), userInput, try color.cyan(allocator, S_BAR_END()) });
            },
        }
    }
};

//
// Asks for a secret. Returns the text (null for undefined), or cancel.
//
pub fn password(allocator: std.mem.Allocator, io: std.Io, opts: PasswordOptions) !PromptResult(?[]const u8) {
    const renderState = try allocator.create(PasswordRender);
    renderState.* = .{ .opts = opts };
    const input = common.resolveInput(io, opts.common);
    input.allocator = allocator;
    const passwordPrompt = try allocator.create(PasswordPrompt);
    passwordPrompt.init(allocator, .{
        .base = .{
            .render = .{ .context = renderState, .function = PasswordRender.render },
            .validate = opts.validate,
            .input = input,
            .output = common.resolveOutput(io, opts.common),
        },
        .mask = opts.mask orelse S_PASSWORD_MASK(),
    });
    const outcome = try passwordPrompt.run();
    return switch (outcome) {
        // The value is undefined (null) when nothing was typed.
        .submit => .{ .value = passwordPrompt.value },
        .cancel => .cancel,
    };
}
