//
// Decides whether an address is the app's own bundled page. Written once, here, and called by every shell.
//

const types = @import("types.zig");

//
// An address is the app's own when it starts with the app's URL prefix. http, https and mailto addresses are external
// links to open in the system browser. Anything else, including any other file address and any malformed address,
// is blocked.
//
// The prefix must end in a slash, so that "file:///app/dist" does not allow "file:///app/dist-evil/x".
//
pub fn checkUrl(app_url_prefix: []const u8, url: []const u8) types.UrlDecision {
    if (app_url_prefix.len > 0 and app_url_prefix[app_url_prefix.len - 1] == '/' and startsWith(url, app_url_prefix)) {
        if (containsDotDot(url[app_url_prefix.len..])) {
            return .block;
        }
        return .allow;
    }
    if (startsWith(url, "http://") or startsWith(url, "https://") or startsWith(url, "mailto:")) {
        return .open_externally;
    }
    return .block;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) {
        return false;
    }
    return std.mem.eql(u8, text[0..prefix.len], prefix);
}

fn containsDotDot(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "..") != null;
}

const std = @import("std");
