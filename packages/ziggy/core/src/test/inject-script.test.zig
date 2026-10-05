const std = @import("std");
const ziggy = @import("ziggy-core");

test "the embedded inject script is the one that exposes window.ziggy on every platform's channel" {
    const text = ziggy.inject_script.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "window.__ziggyReceive") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window.webkit.messageHandlers.ziggy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window.chrome.webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window.ZiggyAndroid") != null);
}

test "the embedded inject script is NUL terminated, as ziggy_inject_script promises" {
    const text = ziggy.inject_script.text;
    try std.testing.expect(text.len > 0);
    try std.testing.expectEqual(@as(u8, 0), text.ptr[text.len]);
}
