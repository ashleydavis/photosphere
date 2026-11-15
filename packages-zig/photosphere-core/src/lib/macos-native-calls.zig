//
// The results the MacOS app gives to the native calls the background work makes of the platform. Ziggy's MacOS bridge has no native
// call callback, so the core makes these calls itself on MacOS, in place of the native app, with the results the Linux native app gives
// (apps/photosphere/native/linux/src/main.zig). Without it every one of them failed with "... is only available in the Photosphere app
// on a mobile", which failed the app smoke tests of the MacOS release workflow: opening a database logged the error from
// requestNotificationPermission, and the background import and sync never ran.
//
// - requestNotificationPermission: a desktop has no permission to request, so it is always granted.
// - networkConnectionType: a desktop cannot tell Wi-Fi from a wired or a metered connection, so it is "unknown", which is what the page's
//   own network status gives too.
// - backgroundLog: the message goes to standard error, which is the app's log.
//
// Any other method is not something a desktop can do, and the caller reports that.
//

const std = @import("std");
const utils = @import("utils-zig");

//
// What the background work sends with backgroundLog.
//
const IBackgroundLog = struct {
    // Whether the message reports a failure.
    @"error": bool,
    // The message.
    message: []const u8,
};

//
// Makes a native call and returns the JSON text of its result, allocated with the allocator, or null when the method is not one a
// desktop can do. A request that cannot be read is an error that reports it.
//
pub fn call(allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, method, "requestNotificationPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "networkConnectionType")) {
        return "\"unknown\"";
    }
    if (std.mem.eql(u8, method, "backgroundLog")) {
        const parsed = std.json.parseFromSliceLeaky(IBackgroundLog, allocator, request_json, .{}) catch {
            return utils.errors.throwError("backgroundLog needs {{\"error\": true or false, \"message\": text}}, and was given {s}.", .{request_json});
        };
        utils.console.@"error"(parsed.message);
        return "null";
    }
    return null;
}
