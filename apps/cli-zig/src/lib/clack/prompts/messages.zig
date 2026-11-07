const std = @import("std");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const CommonOptions = common.CommonOptions;
const S_BAR_END = common.S_BAR_END;

//
// Writes a cancellation message.
//
pub fn cancel(allocator: std.mem.Allocator, io: std.Io, message: []const u8, opts: CommonOptions) !void {
    const output = common.resolveOutput(io, opts);
    try output.print("{s}  {s}\n\n", .{ try color.gray(allocator, S_BAR_END()), try color.red(allocator, message) });
    try output.flush();
}

//
// Writes an intro title.
//
pub fn intro(io: std.Io, title: []const u8, opts: CommonOptions) !void {
    const output = common.resolveOutput(io, opts);
    try output.print("\n{s}\n", .{title});
    try output.flush();
}

//
// Writes an outro message.
//
pub fn outro(io: std.Io, message: []const u8, opts: CommonOptions) !void {
    const output = common.resolveOutput(io, opts);
    try output.print("\n{s}\n", .{message});
    try output.flush();
}
