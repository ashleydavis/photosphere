//
// The environment variables of the process, for the code Photosphere's core is made of, which reads them with
// `node_utils.process_env.getEnv`. The CLI's `main` hands its environment to `process_env`, but a core a native app hosts has no
// `main` of its own, so without this every variable the settings directory, the vault and the log directory are moved with
// (`PHOTOSPHERE_CONFIG_DIR`, `PHOTOSPHERE_VAULT_DIR`, `PHOTOSPHERE_LOG_DIR`) would be ignored and a test run would work on the real
// settings of the person running it.
//

const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");

const process_env = node_utils.process_env;

//
// Copies the environment of the running process into a map. The map owns its strings.
//
pub fn readProcessEnvironment(allocator: std.mem.Allocator) !std.process.Environ.Map {
    const environ: std.process.Environ = switch (builtin.os.tag) {
        .windows => .{
            .block = .global,
        },
        else => .{
            .block = .{
                .slice = std.mem.span(std.c.environ),
            },
        },
    };
    return try environ.createMap(allocator);
}

//
// Makes the process's environment the one `process_env` reads, unless something has already set one (a test sets its own, and a
// program whose `main` set the environment keeps it). Returns the map, which stays for the life of the process, or null when nothing
// was set here.
//
pub fn adoptProcessEnvironment(allocator: std.mem.Allocator) !?*std.process.Environ.Map {
    if (process_env.getEnvironMap() != null) {
        return null;
    }
    const map = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(map);
    map.* = try readProcessEnvironment(allocator);
    process_env.setEnvironMap(map);
    return map;
}

