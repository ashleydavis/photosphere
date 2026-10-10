const std = @import("std");
const node_utils = @import("node-utils-zig");
const environment = @import("../lib/environment.zig");

const process_env = node_utils.process_env;

test "the process environment is copied into a map that holds the variables the process has" {
    var map = try environment.readProcessEnvironment(std.testing.allocator);
    defer map.deinit();
    // Every process this test runs under has a search path, and it is spelled PATH or Path by the platform, which the map ignores.
    try std.testing.expect(map.get("PATH") != null);
}

test "adopting the process environment makes process_env read it" {
    try std.testing.expect(process_env.getEnvironMap() == null);
    const adopted = (try environment.adoptProcessEnvironment(std.testing.allocator)).?;
    defer {
        process_env.setEnvironMap(null);
        adopted.deinit();
        std.testing.allocator.destroy(adopted);
    }
    try std.testing.expect(process_env.getEnv("PATH") != null);
    try std.testing.expect(process_env.getEnvironMap().? == adopted);
}

test "an environment that was already set is kept, not replaced" {
    var own = std.process.Environ.Map.init(std.testing.allocator);
    defer own.deinit();
    try own.put("ONLY_IN_THE_TEST", "yes");
    process_env.setEnvironMap(&own);
    defer process_env.setEnvironMap(null);
    const adopted = try environment.adoptProcessEnvironment(std.testing.allocator);
    try std.testing.expect(adopted == null);
    try std.testing.expectEqualStrings("yes", process_env.getEnv("ONLY_IN_THE_TEST").?);
}
