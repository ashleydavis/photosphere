//
// Photosphere's Linux native app: what is Photosphere's own (its name, its window and its page) on top of Ziggy's
// native app. The page is embedded in the executable by build.zig.
//

const std = @import("std");
const shell = @import("ziggy-native-linux");

//
// What the core says when the background work reports something, as the core sends it.
//
const IBackgroundLog = struct {
    // Whether the message reports a failure.
    @"error": bool,
    // The message.
    message: []const u8,
};

//
// What the core says when the background work holds the computer awake or lets it go.
//
const IHoldAwake = struct {
    // Whether the computer is to stay awake.
    awake: bool,
};

//
// Answers the requests the core's background work makes of the platform: the connection type, and a notification permission a desktop has no need to ask for, so
// that is always granted. The computer is held from suspending while a pass runs, and what the work reports goes to standard error,
// which is the app's log.
//
fn hostRequest(host: shell.Host, method: []const u8, request_json: []const u8) anyerror!?[]const u8 {
    if (std.mem.eql(u8, method, "requestNotificationPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "networkConnectionType")) {
        // A desktop cannot tell Wi-Fi from a wired or a metered connection, which is what the page's own network status says too.
        return "\"unknown\"";
    }
    if (std.mem.eql(u8, method, "holdAwake")) {
        const parsed = try std.json.parseFromSlice(IHoldAwake, std.heap.c_allocator, request_json, .{});
        defer parsed.deinit();
        host.holdAwake(parsed.value.awake);
        return "null";
    }
    if (std.mem.eql(u8, method, "backgroundLog")) {
        const parsed = try std.json.parseFromSlice(IBackgroundLog, std.heap.c_allocator, request_json, .{});
        defer parsed.deinit();
        std.debug.print("{s}\n", .{parsed.value.message});
        return "null";
    }
    return null;
}

//
// Runs the native app with Photosphere's name, window size and embedded page, and returns the exit code.
//
pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try shell.run(.{
        .host_request = hostRequest,
        .app_id = "au.com.codecapers.photosphere",
        .title = "Photosphere",
        .default_width = 1200,
        .default_height = 800,
        .icon_png = @embedFile("app-icon"),
    }, args);
}
