const std = @import("std");
const ziggy = @import("ziggy-core");
const helpers = @import("helpers.zig");

const core_module = ziggy.core;

//
// A page query hook that says what it was told, so a test can see that the core passed the test mode switch through.
//
fn sayTestMode(core: *core_module.Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = core;
    if (test_mode) {
        return try allocator.dupe(u8, "a=1&mode=on&text=%C3%A9");
    }
    return try allocator.dupe(u8, "a=1&mode=off");
}

fn failToMakeQuery(core: *core_module.Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = core;
    _ = allocator;
    _ = test_mode;
    return error.QueryFailed;
}

const app_with_query = blk: {
    var copy = helpers.app;
    copy.page_query = sayTestMode;
    break :blk copy;
};

const app_with_failing_query = blk: {
    var copy = helpers.app;
    copy.page_query = failToMakeQuery;
    break :blk copy;
};

test "an app with no page query hook has an empty query" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    const query = try core.pageQuery();
    try std.testing.expectEqualStrings("", query);
}

test "the query the app makes is passed through unread, with a terminator" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try core_module.Core.create(std.testing.allocator, shell.config(1, 1), app_with_query);
    defer core.destroy();
    const query = try core.pageQuery();
    try std.testing.expectEqualStrings("a=1&mode=off", query);
    try std.testing.expectEqual(@as(u8, 0), query.ptr[query.len]);
}

test "the app is told whether the test mode switch is on" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    var config = shell.config(1, 1);
    // The switch is read from the configuration. The control connection that the switch starts in a test hooks build is not wanted
    // here, so the hook is called with the configuration of a core that has not turned it on.
    config.test_mode = false;
    const core = try core_module.Core.create(std.testing.allocator, config, app_with_query);
    defer core.destroy();
    core.config.test_mode = true;
    const query = try core.pageQuery();
    try std.testing.expectEqualStrings("a=1&mode=on&text=%C3%A9", query);
}

test "asking again replaces the earlier query" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try core_module.Core.create(std.testing.allocator, shell.config(1, 1), app_with_query);
    defer core.destroy();
    _ = try core.pageQuery();
    core.config.test_mode = true;
    const query = try core.pageQuery();
    try std.testing.expectEqualStrings("a=1&mode=on&text=%C3%A9", query);
}

test "a query the app fails to make is an error, not an empty query" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try core_module.Core.create(std.testing.allocator, shell.config(1, 1), app_with_failing_query);
    defer core.destroy();
    try std.testing.expectError(error.QueryFailed, core.pageQuery());
}
