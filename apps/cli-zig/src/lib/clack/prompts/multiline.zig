const std = @import("std");
const core = @import("../core/index.zig");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const multiline_core = @import("../core/prompts/multiline.zig");
const MultilinePrompt = core.MultilinePrompt;
const MultilineValidateFn = multiline_core.MultilineValidateFn;
const PromptResult = core.PromptResult;
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;
const S_BAR_END = common.S_BAR_END;
const symbol = common.symbol;

//
// Options for the multiline() prompt.
//
pub const MultilineOptions = struct {
    // The streams of the prompt.
    common: CommonOptions = .{},

    //
    // Label shown above the input area.
    //
    message: []const u8,

    //
    // Optional validation run when the user presses Ctrl+D.
    // Return a string or Error to block submission and show an error.
    //
    validate: ?MultilineValidateFn = null,
};

//
// The state of the render function of a multiline prompt.
//
const MultilineRender = struct {
    // The options of the prompt.
    opts: MultilineOptions,

    //
    // Renders a frame of the multiline prompt.
    //
    fn render(context: *anyopaque, prompt: *MultilinePrompt) anyerror!?[]const u8 {
        const self: *MultilineRender = @ptrCast(@alignCast(context));
        const allocator = prompt.allocator;
        const title = try std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ try symbol(allocator, prompt.state), self.opts.message });
        var allLines: std.ArrayList([]const u8) = .empty;
        try allLines.appendSlice(allocator, prompt.completedLines.items);
        try allLines.append(allocator, prompt.currentLine);

        switch (prompt.state) {
            .@"error" => {
                var linesText: std.ArrayList([]const u8) = .empty;
                for (allLines.items) |line| {
                    try linesText.append(allocator, try std.fmt.allocPrint(allocator, "{s}  {s}", .{ try color.yellow(allocator, S_BAR()), line }));
                }
                return try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}  {s}\n", .{ std.mem.trim(u8, title, " \t\n\r"), try std.mem.join(allocator, "\n", linesText.items), try color.yellow(allocator, S_BAR_END()), try color.yellow(allocator, prompt.@"error") });
            },
            .submit => {
                var lineCount: usize = 0;
                for (allLines.items) |line| {
                    if (line.len > 0) {
                        lineCount += 1;
                    }
                }
                const summary = try std.fmt.allocPrint(allocator, "{d} line{s}", .{ lineCount, if (lineCount == 1) "" else "s" });
                return try std.fmt.allocPrint(allocator, "{s}{s}  {s}", .{ title, try color.gray(allocator, S_BAR()), try color.dim(allocator, summary) });
            },
            .cancel => {
                return try std.fmt.allocPrint(allocator, "{s}{s}", .{ title, try color.gray(allocator, S_BAR()) });
            },
            else => {
                var linesText: std.ArrayList([]const u8) = .empty;
                for (allLines.items, 0..) |line, lineIndex| {
                    const isCurrentLine = lineIndex == allLines.items.len - 1;
                    if (isCurrentLine) {
                        const before = line[0..prompt.cursorPos];
                        const at_length = if (prompt.cursorPos < line.len) std.unicode.utf8ByteSequenceLength(line[prompt.cursorPos]) catch 1 else 0;
                        const atCursor = line[prompt.cursorPos .. prompt.cursorPos + at_length];
                        const after = line[prompt.cursorPos + at_length ..];
                        const cursorChar = if (atCursor.len > 0) try color.inverse(allocator, atCursor) else try color.inverse(allocator, try color.hidden(allocator, "_"));
                        try linesText.append(allocator, try std.fmt.allocPrint(allocator, "{s}  {s}{s}{s}", .{ try color.cyan(allocator, S_BAR()), before, cursorChar, after }));
                    }
                    else {
                        try linesText.append(allocator, try std.fmt.allocPrint(allocator, "{s}  {s}", .{ try color.cyan(allocator, S_BAR()), line }));
                    }
                }
                return try std.fmt.allocPrint(allocator, "{s}{s}\n{s}  {s}\n", .{ title, try std.mem.join(allocator, "\n", linesText.items), try color.cyan(allocator, S_BAR_END()), try color.dim(allocator, "Ctrl+D to submit") });
            },
        }
    }
};

//
// Renders a multiline text input prompt.
// Enter adds a new line; Ctrl+D submits; Ctrl+C cancels.
//
pub fn multiline(allocator: std.mem.Allocator, io: std.Io, opts: MultilineOptions) !PromptResult([]const u8) {
    const renderState = try allocator.create(MultilineRender);
    renderState.* = .{ .opts = opts };
    const input = common.resolveInput(io, opts.common);
    input.allocator = allocator;
    const multilinePrompt = try allocator.create(MultilinePrompt);
    multilinePrompt.* = MultilinePrompt.init(allocator, .{
        .render = .{ .context = renderState, .function = MultilineRender.render },
        .validate = opts.validate,
        .input = input,
        .output = common.resolveOutput(io, opts.common),
    });
    const outcome = try multilinePrompt.prompt();
    return switch (outcome) {
        .submit => .{ .value = try multilinePrompt.getValue() },
        .cancel => .cancel,
    };
}
