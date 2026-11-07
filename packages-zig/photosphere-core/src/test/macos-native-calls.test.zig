const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const macos_native_calls = @import("photosphere-core").macos_native_calls;

const MacosNativeCalls = macos_native_calls.MacosNativeCalls;

test "MacosNativeCalls grants the notification permission, as a desktop has none to request" {
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    const result = (try native_calls.call(std.testing.allocator, "requestNotificationPermission", "null")).?;
    try std.testing.expectEqualStrings("{\"granted\":true}", result);
}

test "MacosNativeCalls gives the connection type as unknown" {
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    const result = (try native_calls.call(std.testing.allocator, "networkConnectionType", "null")).?;
    try std.testing.expectEqualStrings("\"unknown\"", result);
}

test "MacosNativeCalls writes what the background work reports to standard error" {
    var console_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_out.deinit();
    var console_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_err.deinit();
    utils.console.setCapture(&console_out.writer, &console_err.writer);
    defer utils.console.setCapture(null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    const result = (try native_calls.call(arena.allocator(), "backgroundLog", "{\"error\":false,\"message\":\"Synced 3 files.\"}")).?;
    try std.testing.expectEqualStrings("null", result);
    try std.testing.expectEqualStrings("Synced 3 files.\n", console_err.written());
    try std.testing.expectEqualStrings("", console_out.written());
}

test "MacosNativeCalls refuses a background report it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    try std.testing.expectError(error.Thrown, native_calls.call(arena.allocator(), "backgroundLog", "{\"message\":3}"));
    try std.testing.expectEqualStrings("backgroundLog needs {\"error\": true or false, \"message\": text}, and was given {\"message\":3}.", utils.errors.lastErrorMessage());
}

test "MacosNativeCalls does not know a native call only a phone can make" {
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    try std.testing.expect((try native_calls.call(std.testing.allocator, "exportFile", "{\"path\":\"a.jpg\"}")) == null);
}

test "MacosNativeCalls holds the computer awake with nested holds, and refuses to let go of a hold never taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    if (builtin.os.tag != .macos) {
        try std.testing.expectError(error.Thrown, native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":true}"));
        try std.testing.expectEqualStrings("MacosNativeCalls cannot hold the computer awake on " ++ @tagName(builtin.os.tag) ++ ".", utils.errors.lastErrorMessage());
        return;
    }
    try std.testing.expectEqualStrings("null", (try native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":true}")).?);
    try std.testing.expect(native_calls.assertion_id != null);
    try std.testing.expectEqual(@as(u32, 1), native_calls.awake_holds);
    try std.testing.expectEqualStrings("null", (try native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":true}")).?);
    try std.testing.expectEqual(@as(u32, 2), native_calls.awake_holds);
    try std.testing.expectEqualStrings("null", (try native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":false}")).?);
    try std.testing.expect(native_calls.assertion_id != null);
    try std.testing.expectEqualStrings("null", (try native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":false}")).?);
    try std.testing.expectEqual(@as(u32, 0), native_calls.awake_holds);
    try std.testing.expect(native_calls.assertion_id == null);
    try std.testing.expectError(error.Thrown, native_calls.call(arena.allocator(), "holdAwake", "{\"awake\":false}"));
    try std.testing.expectEqualStrings("A hold on the computer staying awake was let go that was never taken.", utils.errors.lastErrorMessage());
}

test "MacosNativeCalls refuses a hold it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_calls = MacosNativeCalls.init();
    defer native_calls.deinit();
    try std.testing.expectError(error.Thrown, native_calls.call(arena.allocator(), "holdAwake", "{}"));
    try std.testing.expectEqualStrings("holdAwake needs {\"awake\": true or false}, and was given {}.", utils.errors.lastErrorMessage());
}
