const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const limit_options = @import("limit-options.zig");
const select_core = @import("../core/prompts/select.zig");
const SelectPrompt = core.SelectPrompt;
const Prompt = core.Prompt;
const PromptResult = core.PromptResult;
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_BAR_END = common.S_BAR_END;
const S_RADIO_ACTIVE = common.S_RADIO_ACTIVE;
const S_RADIO_INACTIVE = common.S_RADIO_INACTIVE;
const symbol = common.symbol;
const limitOptions = limit_options.limitOptions;

//
// An option of the select prompt (string values only, the only kind the CLI uses).
//
pub const Option = select_core.SelectOption;

//
// Options of the select prompt.
//
pub const SelectOptions = struct {
    // The streams of the prompt.
    common: CommonOptions = .{},

    // The question.
    message: []const u8,

    // The options to choose from (at least one).
    options: []const Option,

    // The value of the initially selected option.
    initialValue: ?[]const u8 = null,

    // The maximum number of options shown at once.
    maxItems: ?usize = null,
};

//
// The state in which an option is drawn.
//
const OptionState = enum {
    // Not under the cursor.
    inactive,

    // Under the cursor.
    active,

    // Submitted.
    selected,

    // Cancelled.
    cancelled,
};

//
// Draws an option.
//
fn opt(allocator: std.mem.Allocator, option: Option, state: OptionState) ![]const u8 {
    const label = option.label orelse option.value;
    switch (state) {
        .selected => return color.dim(allocator, label),
        .active => {
            const hint = if (option.hint) |hintText| try std.fmt.allocPrint(allocator, " {s}", .{try color.dim(allocator, try std.fmt.allocPrint(allocator, "({s})", .{hintText}))}) else "";
            return std.fmt.allocPrint(allocator, "{s} {s}{s}", .{ try color.green(allocator, S_RADIO_ACTIVE()), label, hint });
        },
        .cancelled => return color.strikethrough(allocator, try color.dim(allocator, label)),
        .inactive => return std.fmt.allocPrint(allocator, "{s} {s}", .{ try color.dim(allocator, S_RADIO_INACTIVE()), try color.dim(allocator, label) }),
    }
}

//
// The style function passed to limitOptions.
//
fn styleOption(allocator: std.mem.Allocator, context: *anyopaque, option: Option, active: bool) anyerror![]const u8 {
    _ = context;
    return opt(allocator, option, if (active) .active else .inactive);
}

//
// The state of the render function of a select prompt.
//
const SelectRender = struct {
    // The options of the prompt.
    opts: SelectOptions,

    //
    // Renders a frame of the select prompt.
    //
    fn render(context: *anyopaque, prompt: *Prompt) anyerror!?[]const u8 {
        const self: *SelectRender = @ptrCast(@alignCast(context));
        const selectPrompt = prompt.kind.select;
        const allocator = prompt.allocator;
        const title = try std.fmt.allocPrint(allocator, "{s}\n{s}  {s}\n", .{ try color.gray(allocator, S_BAR()), try symbol(allocator, prompt.state), self.opts.message });

        switch (prompt.state) {
            .submit => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}", .{ title, try color.gray(allocator, S_BAR()), try opt(allocator, selectPrompt.options[selectPrompt.cursor], .selected) });
            },
            .cancel => {
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}\n{s}", .{ title, try color.gray(allocator, S_BAR()), try opt(allocator, selectPrompt.options[selectPrompt.cursor], .cancelled), try color.gray(allocator, S_BAR()) });
            },
            else => {
                const lines = try limitOptions(Option, allocator, .{
                    .cursor = selectPrompt.cursor,
                    .options = selectPrompt.options,
                    .maxItems = self.opts.maxItems,
                    .rows = if (self.opts.common.output != null) null else limit_options.stdoutRows(),
                    .style = styleOption,
                    .styleContext = self,
                });
                const separator = try std.fmt.allocPrint(allocator, "\n{s}  ", .{try color.cyan(allocator, S_BAR())});
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}\n{s}\n", .{ title, try color.cyan(allocator, S_BAR()), try std.mem.join(allocator, separator, lines), try color.cyan(allocator, S_BAR_END()) });
            },
        }
    }
};

//
// Asks the user to pick one of the options. Returns the value of the selected option, or cancel.
//
pub fn select(allocator: std.mem.Allocator, io: std.Io, opts: SelectOptions) !PromptResult([]const u8) {
    const renderState = try allocator.create(SelectRender);
    renderState.* = .{ .opts = opts };
    const input = common.resolveInput(io, opts.common);
    input.allocator = allocator;
    const selectPrompt = try allocator.create(SelectPrompt);
    selectPrompt.init(allocator, .{
        .base = .{
            .render = .{ .context = renderState, .function = SelectRender.render },
            .input = input,
            .output = common.resolveOutput(io, opts.common),
        },
        .options = opts.options,
        .initialValue = opts.initialValue,
    });
    const outcome = try selectPrompt.run();
    return switch (outcome) {
        .submit => .{ .value = selectPrompt.value },
        .cancel => .cancel,
    };
}
