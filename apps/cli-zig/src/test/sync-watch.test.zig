const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const sync_watch = cli.sync_watch;
const parseWatchInterval = sync_watch.parseWatchInterval;
const runSyncWatch = sync_watch.runSyncWatch;

//
// What the watch wrote to stdout and stderr (the test runner talks to the build over stdout, so the log is captured).
//
const Capture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,
};

//
// Counts the syncs a watch runs (TypeScript: the variables the test callbacks capture).
//
const ISyncCounter = struct {
    // The number of syncs run.
    syncs: u32 = 0,

    // The number of syncs that succeeded.
    succeeded: u32 = 0,

    // Stop after this many syncs.
    stopAfter: u32,

    // Fail the first sync.
    failFirst: bool = false,
};

//
// Counts a sync, failing the first one when asked to.
//
fn countSync(context: ?*anyopaque, io: std.Io) anyerror!bool {
    _ = io;
    const counter: *ISyncCounter = @ptrCast(@alignCast(context.?));
    counter.syncs += 1;
    if (counter.failFirst and counter.syncs == 1) {
        return utils.errors.throwError("the network is down", .{});
    }
    counter.succeeded += 1;
    return true;
}

//
// Stops once enough syncs have run.
//
fn stoppedAfterEnough(context: ?*anyopaque) bool {
    const counter: *ISyncCounter = @ptrCast(@alignCast(context.?));
    return counter.syncs >= counter.stopAfter;
}

test "parseWatchInterval uses the default when none was asked for" {
    try std.testing.expectEqual(sync_watch.DEFAULT_SYNC_WATCH_INTERVAL_SECONDS, try parseWatchInterval(null));
}

test "parseWatchInterval takes the number of seconds it was given" {
    try std.testing.expectEqual(@as(f64, 120), try parseWatchInterval("120"));
}

test "parseWatchInterval refuses an interval that is not a number" {
    // Rather than quietly falling back to the default: a watch that syncs every thirty seconds
    // when it was told every hour is exactly the kind of thing nobody notices.
    try std.testing.expectError(error.Thrown, parseWatchInterval("hourly"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "positive number of seconds") != null);
}

test "parseWatchInterval refuses an interval of zero or less" {
    try std.testing.expectError(error.Thrown, parseWatchInterval("0"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "positive number of seconds") != null);
    try std.testing.expectError(error.Thrown, parseWatchInterval("-5"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "positive number of seconds") != null);
}

test "runSyncWatch keeps syncing until it is stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: ISyncCounter = .{ .stopAfter = 3 };
    var capture = Capture{ .stdout = .init(arena.allocator()), .stderr = .init(arena.allocator()) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    try runSyncWatch(arena.allocator(), std.testing.io, .{
        .intervalSeconds = 0.001,
        .context = &counter,
        .syncOnce = countSync,
        .isStopped = stoppedAfterEnough,
    });

    try std.testing.expectEqual(@as(u32, 3), counter.syncs);
}

test "runSyncWatch a sync that failed does not stop the watch" {
    // A network that is down now may be up in thirty seconds. Stopping would mean nothing syncs
    // again until someone notices.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: ISyncCounter = .{ .stopAfter = 3, .failFirst = true };
    var capture = Capture{ .stdout = .init(arena.allocator()), .stderr = .init(arena.allocator()) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    try runSyncWatch(arena.allocator(), std.testing.io, .{
        .intervalSeconds = 0.001,
        .context = &counter,
        .syncOnce = countSync,
        .isStopped = stoppedAfterEnough,
    });

    try std.testing.expectEqual(@as(u32, 3), counter.syncs);
    try std.testing.expectEqual(@as(u32, 2), counter.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, capture.stderr.written(), "\u{2717} Sync failed: the network is down") != null);
}

test "runSyncWatch does not sync at all when it is stopped before it starts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var counter: ISyncCounter = .{ .stopAfter = 0 };
    var capture = Capture{ .stdout = .init(arena.allocator()), .stderr = .init(arena.allocator()) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    try runSyncWatch(arena.allocator(), std.testing.io, .{
        .intervalSeconds = 0.001,
        .context = &counter,
        .syncOnce = countSync,
        .isStopped = stoppedAfterEnough,
    });

    try std.testing.expectEqual(@as(u32, 0), counter.syncs);
}

test "runSyncWatch writes the interval as a template string writes a number and waits as setTimeout does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture = Capture{ .stdout = .init(arena.allocator()), .stderr = .init(arena.allocator()) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);
    // picocolors turns colour on for every process on Windows, and the expected line here has none.
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);

    // setTimeout waits 1 ms for a delay under 1 ms or past 2147483647 ms.
    var tiny: ISyncCounter = .{ .stopAfter = 2 };
    try runSyncWatch(arena.allocator(), std.testing.io, .{
        .intervalSeconds = 1e-7,
        .context = &tiny,
        .syncOnce = countSync,
        .isStopped = stoppedAfterEnough,
    });
    var huge: ISyncCounter = .{ .stopAfter = 2 };
    try runSyncWatch(arena.allocator(), std.testing.io, .{
        .intervalSeconds = 1e21,
        .context = &huge,
        .syncOnce = countSync,
        .isStopped = stoppedAfterEnough,
    });

    try std.testing.expectEqual(@as(u32, 2), huge.syncs);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "Syncing every 1e-7 second(s). Press Ctrl-C to stop.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.stdout.written(), "Syncing every 1e+21 second(s). Press Ctrl-C to stop.\n") != null);
}
