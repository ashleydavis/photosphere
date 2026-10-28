const std = @import("std");
const node_utils = @import("node-utils-zig");

//
// Gives the code under test the environment the test program inherited, which it reads through process_env, until restore is
// called. The bundled FFmpeg writes its report under the OS temp directory, which on Windows comes from TEMP: with no environment
// set it was "undefined\temp", and every ffprobe and ffmpeg run in these tests failed there.
//
pub fn inherit(allocator: std.mem.Allocator) !*std.process.Environ.Map {
    const map = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(map);
    map.* = try std.testing.environ.createMap(allocator);
    node_utils.process_env.setEnvironMap(map);
    return map;
}

//
// Puts the environment back to none, as the other tests expect, and frees the map inherit made.
//
pub fn restore(allocator: std.mem.Allocator, map: *std.process.Environ.Map) void {
    node_utils.process_env.setEnvironMap(null);
    map.deinit();
    allocator.destroy(map);
}
