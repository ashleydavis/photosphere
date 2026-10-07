const std = @import("std");
const cli = @import("cli-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const MockLog = @import("mock-log.zig").MockLog;
const check_for_updates = cli.check_for_updates;

test "tagName reads the release response as response.json() and the tag_name checks do" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("v1.2.3", check_for_updates.tagName(allocator, "{\"tag_name\":\"v1.2.3\"}").?);

    // JSON.parse keeps the last value of a repeated key.
    try std.testing.expectEqualStrings("v2.0.0", check_for_updates.tagName(allocator, "{\"tag_name\":\"v1.2.3\",\"tag_name\":\"v2.0.0\"}").?);

    // An empty tag, a tag that is not a string, a body that is not an object and a body that is not JSON give none.
    try std.testing.expect(check_for_updates.tagName(allocator, "{\"tag_name\":\"\"}") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "{\"tag_name\":5}") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "null") == null);
    try std.testing.expect(check_for_updates.tagName(allocator, "not json") == null);
}

//
// Points the config dir at a path in the root (TypeScript: the mocked setLastShownUpdateVersion of node-api).
//
fn setConfigDir(allocator: std.mem.Allocator, configDir: []const u8) !void {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("PHOTOSPHERE_CONFIG_DIR", configDir);
    node_utils.process_env.setEnvironMap(map);
}

test "markUpdateAsShown persists the supplied version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "mark-update");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try setConfigDir(allocator, try std.fs.path.join(allocator, &.{ root, "config" }));
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    check_for_updates.markUpdateAsShown(allocator, std.testing.io, "1.3.0");

    const lastShown = try node_api.news_state.getLastShownUpdateVersion(allocator, std.testing.io);
    try std.testing.expectEqualStrings("1.3.0", lastShown.?);
}

test "markUpdateAsShown swallows persistence errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "mark-update-fails");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const blocker = try std.fs.path.join(allocator, &.{ root, "config" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = blocker, .data = "not a directory" });
    try setConfigDir(allocator, blocker);
    defer node_utils.process_env.setEnvironMap(null);
    var mock = MockLog.init(allocator);
    mock.install();
    defer mock.uninstall();

    // A file where the config dir should be, so the state file cannot be written (TypeScript: setLastShownUpdateVersion rejects with "disk full").
    check_for_updates.markUpdateAsShown(allocator, std.testing.io, "1.3.0");

    try std.testing.expect(!node_utils.fs.pathExists(std.testing.io, try std.fs.path.join(allocator, &.{ blocker, "state.yaml" })));
}
