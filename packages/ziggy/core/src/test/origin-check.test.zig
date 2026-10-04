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
