const std = @import("std");
const color = @import("../../picocolors.zig");
const common = @import("common.zig");
const string_width = @import("../third-party/string-width.zig");
const commander = @import("../../commander.zig");
const CommonOptions = common.CommonOptions;
const S_BAR = common.S_BAR;

//
// Options of a note.
//
pub const NoteOptions = struct {
    // The streams of the note.
    common: CommonOptions = .{},

    // Formats each line of the message (color.dim when null).
    format: ?*const fn (allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![]const u8 = null,
};

//
// The default line formatter (`(line) => color.dim(line)`).
//
fn defaultNoteFormatter(allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![]const u8 {
    return color.dim(allocator, line);
}

//
// The JavaScript length of a text once its control sequences are stripped (`strip(text).length`).
//
fn strippedLength(allocator: std.mem.Allocator, text: []const u8) !usize {
    return commander.jsLength(try string_width.stripAnsi(allocator, text));
}

//
// Writes a message in a box of bars, under a title.
//
pub fn note(allocator: std.mem.Allocator, io: std.Io, message: []const u8, title: []const u8, opts: NoteOptions) !void {
    const format = opts.format orelse defaultNoteFormatter;
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(allocator, "");
    var messageLines = std.mem.splitScalar(u8, message, '\n');
    while (messageLines.next()) |line| {
        try lines.append(allocator, try format(allocator, line));
    }
    try lines.append(allocator, "");
    const titleLen = try strippedLength(allocator, title);
    const output = common.resolveOutput(io, opts.common);
    var longest: usize = 0;
    for (lines.items) |line| {
        const lineLength = try strippedLength(allocator, line);
        if (lineLength > longest) {
            longest = lineLength;
        }
    }
    const len = @max(longest, titleLen) + 2;
    var msg: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |line, index| {
        if (index > 0) {
            try msg.append(allocator, '\n');
        }
        const padding = try allocator.alloc(u8, len - try strippedLength(allocator, line));
        @memset(padding, ' ');
        try msg.print(allocator, "{s}  {s}{s}{s}", .{ try color.gray(allocator, S_BAR()), line, padding, try color.gray(allocator, S_BAR()) });
    }
    if (title.len > 0) {
        try output.print("   {s}\n{s}\n", .{ try color.reset(allocator, title), msg.items });
    }
    else {
        try output.print("   {s}\n", .{msg.items});
    }
    try output.flush();
}
