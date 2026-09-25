const std = @import("std");

//
// This file has no TypeScript counterpart: it stands in for Node's global `process.env`.
// Zig 0.16 hands the environment to `main` (std.process.Init.environ_map) instead of making it
// global, so `main` calls setEnvironMap once and library code reads variables with getEnv.
// Not threadsafe for writes (like the Environ.Map it wraps): set it before starting threads.
//

//
// The environment of the process, or null when setEnvironMap has not been called.
//
var environ_map: ?*const std.process.Environ.Map = null;

//
// Sets the environment used by getEnv (call from `main` with `init.environ_map`, or from tests).
//
pub fn setEnvironMap(map: ?*const std.process.Environ.Map) void {
    environ_map = map;
}

//
// Equivalent of `process.env[name]`: the value of an environment variable, or null when it is not set
// (or when no environment has been set with setEnvironMap).
//
pub fn getEnv(name: []const u8) ?[]const u8 {
    const map = environ_map orelse return null;
    return map.get(name);
}

//
// Gets the environment set with setEnvironMap (null when none), for passing to child processes
// so they inherit `process.env` like in Node.
//
pub fn getEnvironMap() ?*const std.process.Environ.Map {
    return environ_map;
}
