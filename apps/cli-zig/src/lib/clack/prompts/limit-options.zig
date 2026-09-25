const std = @import("std");
const color = @import("../../picocolors.zig");
const tty = @import("../../tty.zig");

//
// Parameters of limitOptions (the output is always process.stdout here).
//
pub fn LimitOptionsParams(comptime TOption: type) type {
    return struct {
        // The options to show.
        options: []const TOption,

        // The maximum number of items to show (unlimited when null).
        maxItems: ?usize,

        // The index of the active option.
        cursor: usize,

        // True when the output is a TTY with a known row count; the row count (else 10 rows are assumed).
        rows: ?usize,

        // Styles an option (active or not).
        style: *const fn (allocator: std.mem.Allocator, context: *anyopaque, option: TOption, active: bool) anyerror![]const u8,

        // The state of the style function.
        styleContext: *anyopaque,
    };
}

//
// The number of rows of process.stdout (`output.rows`), or null when stdout is not a TTY.
//
pub fn stdoutRows() ?usize {
    return tty.rows(tty.stdout_fd);
}

//
// Limits the options shown to the rows of the terminal, with "..." marking hidden options.
//
pub fn limitOptions(comptime TOption: type, allocator: std.mem.Allocator, params: LimitOptionsParams(TOption)) ![]const []const u8 {
    const cursor = params.cursor;
    const options = params.options;
    const rows = params.rows orelse 10;
    const overflowFormat = try color.dim(allocator, "...");

    const paramMaxItems = params.maxItems orelse std.math.maxInt(usize);
    const outputMaxItems = if (rows > 4) rows - 4 else 0;
    // We clamp to minimum 5 because anything less doesn't make sense UX wise
    const maxItems = @min(outputMaxItems, @max(paramMaxItems, 5));
    var slidingWindowLocation: usize = 0;

    if (cursor + 3 >= slidingWindowLocation + maxItems) {
        const signed_location = @as(i64, @intCast(cursor)) - @as(i64, @intCast(maxItems)) + 3;
        const limit = @as(i64, @intCast(options.len)) - @as(i64, @intCast(maxItems));
        slidingWindowLocation = @intCast(@max(@min(signed_location, limit), 0));
    }
    else if (cursor < slidingWindowLocation + 2) {
        slidingWindowLocation = if (cursor >= 2) cursor - 2 else 0;
    }

    const shouldRenderTopEllipsis = maxItems < options.len and slidingWindowLocation > 0;
    const shouldRenderBottomEllipsis = maxItems < options.len and slidingWindowLocation + maxItems < options.len;

    const window_end = @min(slidingWindowLocation + maxItems, options.len);
    const window = options[@min(slidingWindowLocation, options.len)..window_end];
    var result: std.ArrayList([]const u8) = .empty;
    for (window, 0..) |option, index| {
        const isTopLimit = index == 0 and shouldRenderTopEllipsis;
        const isBottomLimit = index == window.len - 1 and shouldRenderBottomEllipsis;
        if (isTopLimit or isBottomLimit) {
            try result.append(allocator, overflowFormat);
        }
        else {
            try result.append(allocator, try params.style(allocator, params.styleContext, option, index + slidingWindowLocation == cursor));
        }
    }
    return result.items;
}
