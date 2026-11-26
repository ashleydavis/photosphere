//
// Photosphere's Linux native app: what is Photosphere's own (its name, its window and its page) on top of Ziggy's
// native app. The page is embedded in the executable by build.zig.
//

const std = @import("std");
const native_app = @import("ziggy-native-linux");

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
// Handles the native calls the core's background work makes of the platform: the connection type, and the photo library and notification
// permissions, which a desktop has none of to request so both are always granted. What the work reports goes to standard error, which is
// the app's log.
//
fn nativeCall(_: native_app.NativeCallContext, method: []const u8, request_json: []const u8) anyerror!?[]const u8 {
    if (std.mem.eql(u8, method, "requestNotificationPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "requestMediaPermission")) {
        return "{\"granted\":true}";
    }
    if (std.mem.eql(u8, method, "networkConnectionType")) {
        return try readLinuxConnectionType();
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
// Reads the machine's active connection type by following the default route in /proc/net/route to the
// interface that carries it and reading that interface's /sys/class/net entries, and answers one of
// "wifi", "wired", "none" or "unknown" as JSON text. The rule: no default route is none, a wireless interface
// is wifi, a physical interface is wired, anything else is unknown. The native app carries this reading
// because its executable has no dependency on the photosphere-core package.
//
fn readLinuxConnectionType() anyerror![]const u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // /proc/net/route reports a size of 0 through stat, so readFileAlloc reads nothing from it. It is read with a streaming read
    // into a fixed buffer instead; a proc file returns the whole table in one read, and the table is a few hundred bytes for any
    // number of interfaces, so the buffer is far larger than it ever needs to be.
    var route_file = try std.Io.Dir.cwd().openFile(io, "/proc/net/route", .{});
    defer route_file.close(io);
    var route_buffer: [4096]u8 = undefined;
    var route_buffers = [_][]u8{&route_buffer};
    const route_len = try route_file.readStreaming(io, &route_buffers);
    const route_text = route_buffer[0..route_len];

    const interface_name = defaultRouteInterface(route_text) orelse {
        return "\"none\"";
    };

    var wireless_path: [64]u8 = undefined;
    const has_wireless = try entryExists(&wireless_path, io, "wireless", interface_name);
    var device_path: [64]u8 = undefined;
    const has_device = try entryExists(&device_path, io, "device", interface_name);

    if (has_wireless) {
        return "\"wifi\"";
    }
    if (has_device) {
        return "\"wired\"";
    }
    return "\"unknown\"";
}

//
// Whether the /sys/class/net/<interface>/<entry> path exists, which is how a wireless interface (the
// "wireless" directory) and a physical interface (the "device" directory) are told apart. The path is
// written into the given buffer, which is sized for the longest interface name Linux allows.
//
fn entryExists(path_buffer: []u8, io: std.Io, entry: []const u8, interface_name: []const u8) !bool {
    const path = try std.fmt.bufPrint(path_buffer, "/sys/class/net/{s}/{s}", .{ interface_name, entry });
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        return false;
    };
    return true;
}

//
// The interface the default route of /proc/net/route names, or null when the file names none (see
// readLinuxConnectionType).
//
fn defaultRouteInterface(route_text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, route_text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const interface_name = fields.next() orelse {
            continue;
        };
        if (std.mem.eql(u8, interface_name, "Iface")) {
            continue;
        }
        const destination = fields.next() orelse {
            continue;
        };
        if (std.mem.eql(u8, destination, "00000000")) {
            return interface_name;
        }
    }
    return null;
}

//
// Runs the native app with Photosphere's name, window size and embedded page, and returns the exit code.
//
pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try native_app.run(.{
        .native_call = nativeCall,
        .app_id = "au.com.codecapers.photosphere",
        .title = "Photosphere",
        .default_width = 1200,
        .default_height = 800,
        .icon_png = @embedFile("app-icon"),
    }, args);
}
