//
// The answers the MacOS app gives to the host requests the background work makes of the platform. Ziggy's MacOS bridge has no host
// request callback, so the core answers these itself on MacOS, in place of the native app, with what the Linux native app answers
// (apps/photosphere/native/linux/src/main.zig). Without it every one of them failed with "... is only available in the Photosphere app
// on a phone", which failed the app smoke tests of the MacOS release workflow: opening a database logged the error from
// requestNotificationPermission, and the background import and sync never ran.
//
// - requestNotificationPermission: a desktop has no permission to ask for, so it is always granted.
// - networkConnectionType: a desktop cannot tell Wi-Fi from a wired or a metered connection, so it is "unknown", which is what the page's
//   own network status says too.
// - holdAwake: holds the computer from going to sleep while a pass runs, or lets it go. Holds nest, and the computer may sleep again once
//   every hold has been let go. It is an IOKit power assertion (PreventUserIdleSystemSleep), which belongs to the process and not to a
//   thread, so a hold taken on one worker thread and let go on another is still the same hold.
// - backgroundLog: the message goes to standard error, which is the app's log.
//
// Any other method is not something a desktop can do, and the caller says so.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");

//
// What the background work sends with holdAwake.
//
const IHoldAwake = struct {
    // Whether the computer is to stay awake.
    awake: bool,
};

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
// kIOPMAssertionLevelOn: the assertion is in force.
//
const assertion_level_on: u32 = 255;

//
// kCFStringEncodingUTF8.
//
const cf_string_encoding_utf8: u32 = 0x08000100;

extern "c" fn CFStringCreateWithCString(allocator: ?*anyopaque, text: [*:0]const u8, encoding: u32) ?*anyopaque;
extern "c" fn CFRelease(object: *anyopaque) void;
extern "c" fn IOPMAssertionCreateWithName(assertion_type: *anyopaque, level: u32, name: *anyopaque, assertion_id: *u32) i32;
extern "c" fn IOPMAssertionRelease(assertion_id: u32) i32;

//
// The MacOS app's answers to host requests, and the holds it has on the computer staying awake. The main process state owns one.
//
pub const MacosHost = struct {
    // For the mutex.
    io: std.Io,
    // Guards everything below.
    mutex: std.Io.Mutex,
    // How many holds on the computer staying awake have been taken and not let go.
    awake_holds: u32,
    // The power assertion that keeps the computer awake while there is a hold, or null when there is none.
    assertion_id: ?u32,

    //
    // A host with no holds.
    //
    pub fn init(io: std.Io) MacosHost {
        return .{
            .io = io,
            .mutex = .init,
            .awake_holds = 0,
            .assertion_id = null,
        };
    }

    //
    // Releases the power assertion, which lets go of any hold still taken.
    //
    pub fn deinit(self: *MacosHost) void {
        if (builtin.os.tag == .macos) {
            if (self.assertion_id) |assertion_id| {
                _ = IOPMAssertionRelease(assertion_id);
                self.assertion_id = null;
            }
        }
    }

    //
    // Answers a host request with the JSON text of its result, allocated with the allocator, or null when the method is not one a
    // desktop can do. A request that cannot be read, and a hold that MacOS refuses, are errors that say so.
    //
    pub fn answer(self: *MacosHost, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) !?[]const u8 {
        if (std.mem.eql(u8, method, "requestNotificationPermission")) {
            return "{\"granted\":true}";
        }
        if (std.mem.eql(u8, method, "networkConnectionType")) {
            return "\"unknown\"";
        }
        if (std.mem.eql(u8, method, "holdAwake")) {
            const parsed = std.json.parseFromSliceLeaky(IHoldAwake, allocator, request_json, .{}) catch {
                return utils.errors.throwError("holdAwake needs {{\"awake\": true or false}}, and was given {s}.", .{request_json});
            };
            try self.holdAwake(parsed.awake);
            return "null";
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

    //
    // Takes one hold on the computer staying awake, or lets one go. The first hold creates the power assertion, and letting go of the
    // last one releases it. Letting go of a hold that was never taken is an error, as it is on Linux.
    //
    fn holdAwake(self: *MacosHost, awake: bool) !void {
        if (builtin.os.tag != .macos) {
            return utils.errors.throwError("The MacOS host cannot hold the computer awake on {s}.", .{@tagName(builtin.os.tag)});
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (awake) {
            if (self.awake_holds == 0) {
                self.assertion_id = try createAssertion();
            }
            self.awake_holds += 1;
            return;
        }
        if (self.awake_holds == 0) {
            return utils.errors.throwError("A hold on the computer staying awake was let go that was never taken.", .{});
        }
        if (self.awake_holds == 1) {
            const result = IOPMAssertionRelease(self.assertion_id.?);
            if (result != 0) {
                return utils.errors.throwError("MacOS refused to let the computer sleep again: IOPMAssertionRelease failed with error {d}.", .{result});
            }
            self.assertion_id = null;
        }
        self.awake_holds -= 1;
    }
};

//
// Creates the power assertion that stops the computer going to sleep on its own, and returns its id.
//
fn createAssertion() !u32 {
    const assertion_type = CFStringCreateWithCString(null, "PreventUserIdleSystemSleep", cf_string_encoding_utf8) orelse {
        return utils.errors.throwError("MacOS refused to keep the computer awake: CFStringCreateWithCString failed.", .{});
    };
    defer CFRelease(assertion_type);
    const name = CFStringCreateWithCString(null, "Photosphere is working in the background", cf_string_encoding_utf8) orelse {
        return utils.errors.throwError("MacOS refused to keep the computer awake: CFStringCreateWithCString failed.", .{});
    };
    defer CFRelease(name);
    var assertion_id: u32 = 0;
    const result = IOPMAssertionCreateWithName(assertion_type, assertion_level_on, name, &assertion_id);
    if (result != 0) {
        return utils.errors.throwError("MacOS refused to keep the computer awake: IOPMAssertionCreateWithName failed with error {d}.", .{result});
    }
    return assertion_id;
}
