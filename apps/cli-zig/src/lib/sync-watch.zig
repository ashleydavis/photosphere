const std = @import("std");
const utils = @import("utils-zig");
const pc = @import("picocolors.zig");
const init_cmd = @import("init-cmd.zig");
const log = &utils.log.log;
const throwError = utils.errors.throwError;
const errorMessage = utils.errors.errorMessage;
const sleep = utils.sleep.sleep;
const jsNumber = init_cmd.jsNumber;

//
// The watching half of `psi sync`.
//
// `psi sync` pushes what has changed to the origin once. `psi sync --watch` keeps doing it. Run it
// beside `psi add --watch` and that is what `psi watch` used to be, except that each half is
// separately useful and separately testable, where before it was both or neither.
//

//
// How long to wait between syncs when none is asked for, in seconds.
//
pub const DEFAULT_SYNC_WATCH_INTERVAL_SECONDS: f64 = 30;

//
// Reads the interval a watch was asked to run at, in seconds.
//
// Throws rather than falling back to the default, because a mistyped interval that silently syncs
// every thirty seconds instead of every hour is exactly the kind of thing nobody notices.
//
pub fn parseWatchInterval(interval: ?[]const u8) !f64 {
    const text = interval orelse {
        return DEFAULT_SYNC_WATCH_INTERVAL_SECONDS;
    };

    const seconds = jsNumber(text);
    if (!std.math.isFinite(seconds) or seconds <= 0) {
        return throwError("--interval must be a positive number of seconds, got \"{s}\".", .{text});
    }

    return seconds;
}

//
// What a sync watch needs to run.
// (Zig: the callbacks take a context in place of the variables a TypeScript closure captures, and syncOnce
// reports `result.synced` rather than the whole ISyncResult, which is all the watch reads.)
//
pub const ISyncWatchOptions = struct {
    // How long to wait between syncs, in seconds.
    intervalSeconds: f64,

    // The value passed back to syncOnce and isStopped.
    context: ?*anyopaque,

    // Runs one sync and reports whether anything was transferred.
    syncOnce: *const fn (context: ?*anyopaque, io: std.Io) anyerror!bool,

    // True once the watch should stop. Passed in rather than reached for, so the loop can be tested
    // without sending a signal to the test runner.
    isStopped: *const fn (context: ?*anyopaque) bool,
};

//
// Syncs over and over until it is told to stop.
//
// A sync that fails is reported and the watch carries on: a network that is down now may be up in
// thirty seconds, and stopping would mean nothing syncs again until someone notices.
//
pub fn runSyncWatch(allocator: std.mem.Allocator, io: std.Io, options: ISyncWatchOptions) !void {
    log.info(try pc.bold(allocator, try std.fmt.allocPrint(allocator, "Syncing every {d} second(s). Press Ctrl-C to stop.", .{options.intervalSeconds})));

    while (!options.isStopped(options.context)) {
        if (options.syncOnce(options.context, io)) |synced| {
            if (synced) {
                log.info("Sync completed successfully!");
            }
        }
        else |err| {
            log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Sync failed: {s}", .{errorMessage(err)})));
        }

        if (options.isStopped(options.context)) {
            break;
        }

        try sleep(io, @intFromFloat(options.intervalSeconds * 1000));
    }
}
