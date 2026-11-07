const std = @import("std");
const node_utils = @import("node-utils-zig");
const process_env = node_utils.process_env;

test "getEnv returns null until an environment is set" {
    process_env.setEnvironMap(null);
    try std.testing.expect(process_env.getEnv("PATH") == null);
}

test "getEnv reads the environment set with setEnvironMap" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("PHOTOSPHERE_TEST", "value");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("value", process_env.getEnv("PHOTOSPHERE_TEST").?);
    try std.testing.expect(process_env.getEnv("PHOTOSPHERE_MISSING") == null);
}

test "getEnvironMap returns the environment set with setEnvironMap" {
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    process_env.setEnvironMap(&environ_map);
    try std.testing.expect(process_env.getEnvironMap() == &environ_map);
    process_env.setEnvironMap(null);
    try std.testing.expect(process_env.getEnvironMap() == null);
}
