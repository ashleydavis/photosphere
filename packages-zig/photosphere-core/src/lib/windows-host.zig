//
// The answers the Windows app gives to the host requests the background work makes of the platform. Ziggy's Windows shell has no host
// request callback, so the core answers these itself on Windows, in place of the shell, with what the Linux shell answers
// (apps/photosphere/shells/linux/src/main.zig):
//
// - requestNotificationPermission: a desktop has no permission to ask for, so it is always granted.
// - networkConnectionType: a desktop cannot tell Wi-Fi from a wired or a metered connection, so it is "unknown", which is what the page's
//   own network status says too.
// - holdAwake: holds the computer from suspending while a pass runs, or lets it go. Holds nest, and the computer may suspend again once
//   every hold has been let go. It is a Windows power request (PowerSetRequest with PowerRequestSystemRequired) rather than
//   SetThreadExecutionState, because a power request belongs to its handle and not to a thread, so a hold taken on one worker thread
//   and let go on another is still the same hold.
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
// The context of a power request: Windows shows its reason to the user (powercfg /requests). REASON_CONTEXT in the Windows SDK.
//
const ReasonContext = extern struct {
    // POWER_REQUEST_CONTEXT_VERSION.
    version: u32,
    // POWER_REQUEST_CONTEXT_SIMPLE_STRING: the reason is a string.
    flags: u32,
    // The reason.
    reason: extern union {
        // The reason as a resource of a module, which is not used here but sets the size of the union.
        detailed: extern struct {
            // The module holding the string resources.
            localized_reason_module: ?*anyopaque,
            // The resource id of the reason.
            localized_reason_id: u32,
            // The number of strings substituted into it.
            reason_string_count: u32,
            // The strings substituted into it.
            reason_strings: ?[*]?[*:0]u16,
        },
        // The reason as a string.
        simple_reason_string: [*:0]const u16,
    },
};

//
// PowerRequestSystemRequired from POWER_REQUEST_TYPE: the computer does not go to sleep on its own while the request is set.
//
const power_request_system_required: c_int = 1;

extern "kernel32" fn PowerCreateRequest(context: *const ReasonContext) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn PowerSetRequest(request: std.os.windows.HANDLE, request_type: c_int) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn PowerClearRequest(request: std.os.windows.HANDLE, request_type: c_int) callconv(.winapi) std.os.windows.BOOL;

//
// The Windows app's answers to host requests, and the holds it has on the computer staying awake. The main process state owns one.
//
pub const WindowsHost = struct {
    // For the mutex.
    io: std.Io,
    // Guards everything below.
    mutex: std.Io.Mutex,
    // How many holds on the computer staying awake have been taken and not let go.
    awake_holds: u32,
    // The power request that keeps the computer awake, made when the first hold is taken, or null before then. Owned.
    power_request: ?std.os.windows.HANDLE,

    //
    // A host with no holds.
    //
    pub fn init(io: std.Io) WindowsHost {
        return .{
            .io = io,
            .mutex = .init,
            .awake_holds = 0,
            .power_request = null,
        };
    }

    //
    // Closes the power request, which lets go of any hold still taken.
    //
    pub fn deinit(self: *WindowsHost) void {
        if (builtin.os.tag == .windows) {
            if (self.power_request) |request| {
                std.os.windows.CloseHandle(request);
                self.power_request = null;
            }
        }
    }

    //
    // Answers a host request with the JSON text of its result, allocated with the allocator, or null when the method is not one a
    // desktop can do. A request that cannot be read, and a hold that Windows refuses, are errors that say so.
    //
    pub fn answer(self: *WindowsHost, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) !?[]const u8 {
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
    // Takes one hold on the computer staying awake, or lets one go. The first hold sets the power request, and letting go of the last
    // one clears it. Letting go of a hold that was never taken is an error, as it is on Linux.
    //
    fn holdAwake(self: *WindowsHost, awake: bool) !void {
        if (builtin.os.tag != .windows) {
            return utils.errors.throwError("The Windows host cannot hold the computer awake on {s}.", .{@tagName(builtin.os.tag)});
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (awake) {
            if (self.awake_holds == 0) {
                const request = try self.powerRequest();
                if (!PowerSetRequest(request, power_request_system_required).toBool()) {
                    return utils.errors.throwError("Windows refused to keep the computer awake: PowerSetRequest failed with error {d}.", .{@intFromEnum(std.os.windows.GetLastError())});
                }
            }
            self.awake_holds += 1;
            return;
        }
        if (self.awake_holds == 0) {
            return utils.errors.throwError("A hold on the computer staying awake was let go that was never taken.", .{});
        }
        if (self.awake_holds == 1) {
            if (!PowerClearRequest(self.power_request.?, power_request_system_required).toBool()) {
                return utils.errors.throwError("Windows refused to let the computer sleep again: PowerClearRequest failed with error {d}.", .{@intFromEnum(std.os.windows.GetLastError())});
            }
        }
        self.awake_holds -= 1;
    }

    //
    // The power request, made the first time it is needed. The caller holds the mutex.
    //
    fn powerRequest(self: *WindowsHost) !std.os.windows.HANDLE {
        if (self.power_request) |request| {
            return request;
        }
        const context: ReasonContext = .{
            .version = 0,
            .flags = 1,
            .reason = .{
                .simple_reason_string = std.unicode.utf8ToUtf16LeStringLiteral("Photosphere is working in the background"),
            },
        };
        const request = PowerCreateRequest(&context);
        if (request == std.os.windows.INVALID_HANDLE_VALUE) {
            return utils.errors.throwError("Windows refused to keep the computer awake: PowerCreateRequest failed with error {d}.", .{@intFromEnum(std.os.windows.GetLastError())});
        }
        self.power_request = request;
        return request;
    }
};
