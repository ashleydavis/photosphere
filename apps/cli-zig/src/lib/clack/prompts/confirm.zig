const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const ConfirmPrompt = core.ConfirmPrompt;
const Prompt = core.Prompt;
const PromptResult = core.PromptResult;
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_BAR_END = common.S_BAR_END;
const S_RADIO_ACTIVE = common.S_RADIO_ACTIVE;
const S_RADIO_INACTIVE = common.S_RADIO_INACTIVE;
const symbol = common.symbol;

//
// Options of the confirm prompt.
//
pub const ConfirmOptions = struct {
    // The streams of the prompt.
    common: CommonOptions = .{},

    // The question.
    message: []const u8,

    // The label of the "yes" choice (default "Yes").
    active: ?[]const u8 = null,

    // The label of the "no" choice (default "No").
    inactive: ?[]const u8 = null,

    // The initially selected choice (default true).
    initialValue: ?bool = null,
};

//
// The state of the render function of a confirm prompt.
//
const ConfirmRender = struct {
    // The options of the prompt.
    opts: ConfirmOptions,

    // The label of the "yes" choice.
    active: []const u8,

    // The label of the "no" choice.
    inactive: []const u8,

    //
    // Renders a frame of the confirm prompt.
    //
    fn render(context: *anyopaque, prompt: *Prompt) anyerror!?[]const u8 {
        const self: *ConfirmRender = @ptrCast(@alignCast(context));
        const confirmPrompt = prompt.kind.confirm;
        const allocator = prompt.allocator;
        const title = try std.fmt.allocPrint(allocator, "{s}\n{s}  {s}\n", .{ try color.gray(allocator, S_BAR()), try symbol(allocator, prompt.state), self.opts.message });
        const value = if (confirmPrompt.value) self.active else self.inactive;

        switch (prompt.state) {
            .submit => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}", .{ title, try color.gray(allocator, S_BAR()), try color.dim(allocator, value) });
            },
            .cancel => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}\n{s}", .{ title, try color.gray(allocator, S_BAR()), try color.strikethrough(allocator, try color.dim(allocator, value)), try color.gray(allocator, S_BAR()) });
            },
            else => {
                const activeText = if (confirmPrompt.value)
                    try std.fmt.allocPrint(allocator, "{s} {s}", .{ try color.green(allocator, S_RADIO_ACTIVE()), self.active })
                else
                    try std.fmt.allocPrint(allocator, "{s} {s}", .{ try color.dim(allocator, S_RADIO_INACTIVE()), try color.dim(allocator, self.active) });
                const inactiveText = if (!confirmPrompt.value)
                    try std.fmt.allocPrint(allocator, "{s} {s}", .{ try color.green(allocator, S_RADIO_ACTIVE()), self.inactive })
                else
                    try std.fmt.allocPrint(allocator, "{s} {s}", .{ try color.dim(allocator, S_RADIO_INACTIVE()), try color.dim(allocator, self.inactive) });
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s} {s} {s}\n{s}\n", .{ title, try color.cyan(allocator, S_BAR()), activeText, try color.dim(allocator, "/"), inactiveText, try color.cyan(allocator, S_BAR_END()) });
            },
        }
    }
};

//
// Asks a yes/no question. Returns the answer, or cancel.
//
pub fn confirm(allocator: std.mem.Allocator, io: std.Io, opts: ConfirmOptions) !PromptResult(bool) {
    const renderState = try allocator.create(ConfirmRender);
    renderState.* = .{
        .opts = opts,
        .active = opts.active orelse "Yes",
        .inactive = opts.inactive orelse "No",
    };
    const input = common.resolveInput(io, opts.common);
    input.allocator = allocator;
    const confirmPrompt = try allocator.create(ConfirmPrompt);
    confirmPrompt.init(allocator, .{
        .base = .{
            .render = .{ .context = renderState, .function = ConfirmRender.render },
            .input = input,
            .output = common.resolveOutput(io, opts.common),
        },
        .active = renderState.active,
        .inactive = renderState.inactive,
        .initialValue = opts.initialValue orelse true,
    });
    const outcome = try confirmPrompt.run();
    return switch (outcome) {
        .submit => .{ .value = confirmPrompt.value },
        .cancel => .cancel,
    };
}
