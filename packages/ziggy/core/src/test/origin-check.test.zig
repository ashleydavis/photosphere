const std = @import("std");
const ziggy = @import("ziggy-core");

const prefix = "file:///app/dist/";

test "the app's own page is allowed" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, ziggy.origin_check.checkUrl(prefix, "file:///app/dist/index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, ziggy.origin_check.checkUrl(prefix, "file:///app/dist/assets/main.js"));
}

test "another file address is blocked" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, "file:///etc/passwd"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, "file:///app/dist-evil/index.html"));
}

test "a path that climbs out of the app's directory is blocked" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, "file:///app/dist/../secret.txt"));
}

test "http, https and mailto addresses are opened in the system browser" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.open_externally, ziggy.origin_check.checkUrl(prefix, "http://example.com/"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.open_externally, ziggy.origin_check.checkUrl(prefix, "https://example.com/a?b=c"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.open_externally, ziggy.origin_check.checkUrl(prefix, "mailto:someone@example.com"));
}

test "a malformed address is blocked" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, ""));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, "javascript:alert(1)"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(prefix, "not a url"));
}

test "a prefix that does not end in a slash allows nothing" {
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl("file:///app/dist", "file:///app/dist/index.html"));
}

test "a page served under the ziggy-app scheme is allowed, and another host or scheme is blocked" {
    const scheme_prefix = "ziggy-app://app/";
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, ziggy.origin_check.checkUrl(scheme_prefix, "ziggy-app://app/index.html?testMode=1"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(scheme_prefix, "ziggy-app://other/index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(scheme_prefix, "ziggy-app://app/../index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.block, ziggy.origin_check.checkUrl(scheme_prefix, "file:///app/index.html"));
}

test "a page served from the Windows shell's reserved host is allowed, and a host that merely starts with it is not" {
    const windows_prefix = "https://ziggy-app.invalid/";
    try std.testing.expectEqual(ziggy.types.UrlDecision.allow, ziggy.origin_check.checkUrl(windows_prefix, "https://ziggy-app.invalid/assets/main.js"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.open_externally, ziggy.origin_check.checkUrl(windows_prefix, "https://ziggy-app.invalid.example.com/index.html"));
    try std.testing.expectEqual(ziggy.types.UrlDecision.open_externally, ziggy.origin_check.checkUrl(windows_prefix, "https://example.com/"));
}
