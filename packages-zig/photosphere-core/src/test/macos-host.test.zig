const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const macos_host = @import("../lib/macos-host.zig");

const MacosHost = macos_host.MacosHost;

test "the MacOS host grants the notification permission, as a desktop has none to ask for" {
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    const answer = (try host.answer(std.testing.allocator, "requestNotificationPermission", "null")).?;
    try std.testing.expectEqualStrings("{\"granted\":true}", answer);
}

test "the MacOS host says the connection type is unknown" {
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    const answer = (try host.answer(std.testing.allocator, "networkConnectionType", "null")).?;
    try std.testing.expectEqualStrings("\"unknown\"", answer);
}

test "the MacOS host writes what the background work reports to standard error" {
    var console_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_out.deinit();
    var console_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_err.deinit();
    utils.console.setCapture(&console_out.writer, &console_err.writer);
    defer utils.console.setCapture(null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    const answer = (try host.answer(arena.allocator(), "backgroundLog", "{\"error\":false,\"message\":\"Synced 3 files.\"}")).?;
    try std.testing.expectEqualStrings("null", answer);
    try std.testing.expectEqualStrings("Synced 3 files.\n", console_err.written());
    try std.testing.expectEqualStrings("", console_out.written());
}

test "the MacOS host refuses a background report it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    try std.testing.expectError(error.Thrown, host.answer(arena.allocator(), "backgroundLog", "{\"message\":3}"));
    try std.testing.expectEqualStrings("backgroundLog needs {\"error\": true or false, \"message\": text}, and was given {\"message\":3}.", utils.errors.lastErrorMessage());
}

test "the MacOS host does not know a request only a phone can answer" {
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    try std.testing.expect((try host.answer(std.testing.allocator, "exportFile", "{\"path\":\"a.jpg\"}")) == null);
}

test "the MacOS host holds the computer awake with nested holds, and refuses to let go of a hold never taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    if (builtin.os.tag != .macos) {
        try std.testing.expectError(error.Thrown, host.answer(arena.allocator(), "holdAwake", "{\"awake\":true}"));
        try std.testing.expectEqualStrings("The MacOS host cannot hold the computer awake on " ++ @tagName(builtin.os.tag) ++ ".", utils.errors.lastErrorMessage());
        return;
    }
    try std.testing.expectEqualStrings("null", (try host.answer(arena.allocator(), "holdAwake", "{\"awake\":true}")).?);
    try std.testing.expect(host.assertion_id != null);
    try std.testing.expectEqual(@as(u32, 1), host.awake_holds);
    try std.testing.expectEqualStrings("null", (try host.answer(arena.allocator(), "holdAwake", "{\"awake\":true}")).?);
    try std.testing.expectEqual(@as(u32, 2), host.awake_holds);
    try std.testing.expectEqualStrings("null", (try host.answer(arena.allocator(), "holdAwake", "{\"awake\":false}")).?);
    try std.testing.expect(host.assertion_id != null);
    try std.testing.expectEqualStrings("null", (try host.answer(arena.allocator(), "holdAwake", "{\"awake\":false}")).?);
    try std.testing.expectEqual(@as(u32, 0), host.awake_holds);
    try std.testing.expect(host.assertion_id == null);
    try std.testing.expectError(error.Thrown, host.answer(arena.allocator(), "holdAwake", "{\"awake\":false}"));
    try std.testing.expectEqualStrings("A hold on the computer staying awake was let go that was never taken.", utils.errors.lastErrorMessage());
}

test "the MacOS host refuses a hold it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MacosHost.init(std.testing.io);
    defer host.deinit();
    try std.testing.expectError(error.Thrown, host.answer(arena.allocator(), "holdAwake", "{}"));
    try std.testing.expectEqualStrings("holdAwake needs {\"awake\": true or false}, and was given {}.", utils.errors.lastErrorMessage());
}
