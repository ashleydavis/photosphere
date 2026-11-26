const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const macos_native_calls = @import("macos-native-calls");

test "macos_native_calls.call grants the notification permission, as a desktop has none to request" {
    const result = (try macos_native_calls.call(std.testing.allocator, "requestNotificationPermission", "null")).?;
    try std.testing.expectEqualStrings("{\"granted\":true}", result);
}

test "macos_native_calls.call reads the connection type only on macOS" {
    const result = try macos_native_calls.call(std.testing.allocator, "networkConnectionType", "null");
    if (builtin.os.tag != .macos) {
        // The reader is not compiled on any other platform, so the call answers null and the
        // the classification runs only on its own platform, checked by CI.
        try std.testing.expect(result == null);
    } else {
        try std.testing.expect(result != null);
    }
}

test "macos_native_calls.call writes what the background work reports to standard error" {
    var console_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_out.deinit();
    var console_err = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer console_err.deinit();
    utils.console.setCapture(&console_out.writer, &console_err.writer);
    defer utils.console.setCapture(null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = (try macos_native_calls.call(arena.allocator(), "backgroundLog", "{\"error\":false,\"message\":\"Synced 3 files.\"}")).?;
    try std.testing.expectEqualStrings("null", result);
    try std.testing.expectEqualStrings("Synced 3 files.\n", console_err.written());
    try std.testing.expectEqualStrings("", console_out.written());
}

test "macos_native_calls.call refuses a background report it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, macos_native_calls.call(arena.allocator(), "backgroundLog", "{\"message\":3}"));
    try std.testing.expectEqualStrings("backgroundLog needs {\"error\": true or false, \"message\": text}, and was given {\"message\":3}.", utils.errors.lastErrorMessage());
}

test "macos_native_calls.call does not know a native call only a mobile can make" {
    try std.testing.expect((try macos_native_calls.call(std.testing.allocator, "exportFile", "{\"path\":\"a.jpg\"}")) == null);
}
