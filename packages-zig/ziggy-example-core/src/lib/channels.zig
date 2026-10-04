//
// The example's channel handlers.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

//
// Replies with the Zig version, the target operating system and CPU architecture, and an echo of the payload.
//
pub fn pingHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    return try ziggy.json_util.stringify(arena, .{
        .zigVersion = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .echo = data,
    });
}

//
// Replies with the length in bytes and the CRC-32 of the "text" field, so the page can check a large payload
// arrived whole without the payload coming back.
//
pub fn payloadStatsHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    const text = ziggy.json_util.getString(data, "text") orelse {
        return error.MissingText;
    };
    return try ziggy.json_util.stringify(arena, .{
        .length = text.len,
        .crc32 = std.hash.Crc32.hash(text),
        .text = text[0..@min(text.len, 64)],
    });
}

//
// Writes the "text" field to a file in the app's private data directory, reads it back and replies with what it read.
// A data directory that does not exist is an error.
//
pub fn fileRoundtripHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const text = ziggy.json_util.getString(data, "text") orelse {
        return error.MissingText;
    };
    const path = try std.fs.path.join(arena, &.{ core.data_dir, "ziggy-example-roundtrip.txt" });
    const io = core.io();
    var directory = try std.Io.Dir.cwd().openDir(io, core.data_dir, .{});
    directory.close(io);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = text,
    });
    const read_back = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
    return try ziggy.json_util.stringify(arena, .{
        .path = path,
        .text = read_back,
    });
}

//
// Always fails, so the page can check that an error reply reaches it.
//
pub fn failHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    _ = arena;
    _ = data;
    return error.ExampleFailure;
}
