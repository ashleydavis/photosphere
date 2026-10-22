const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const background_work = @import("photosphere-core").background_work;

const MainState = main_state.MainState;
const TestApp = support.TestApp;

// Where the sync pass is in the state's arrays, which are indexed by pass.
const sync_index = @intFromEnum(background_work.Pass.sync);

// Where the prefetch pass is in the state's arrays.
const prefetch_index = @intFromEnum(background_work.Pass.prefetch);

//
// Waits until the native app has been told as many keep-alive changes as are expected, and checks they are the ones expected.
//
fn expectKeepAliveCalls(app: *TestApp, expected: []const bool) !void {
    const io = app.shell.threaded.io();
    var waited_ms: u32 = 0;
    while (waited_ms < 2_000) : (waited_ms += 1) {
        app.shell.mutex.lockUncancelable(io);
        const have = app.shell.keep_alive_calls.items.len;
        app.shell.mutex.unlock(io);
        if (have >= expected.len) {
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    app.shell.mutex.lockUncancelable(io);
    defer app.shell.mutex.unlock(io);
    try std.testing.expectEqualSlices(bool, expected, app.shell.keep_alive_calls.items);
}

//
// Stops the state's timer thread, so a test of the background pass bookkeeping is not raced by the timer starting a pass that is due.
//
fn stopTimerThread(state: *MainState) void {
    state.stopping.store(true, .release);
    if (state.timer_thread) |thread| {
        thread.join();
        state.timer_thread = null;
    }
    state.stopping.store(false, .release);
}

//
// A task that sends an event and then runs until it is cancelled.
//
fn spinTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .spinning = true });
    while (true) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(2), .awake);
    }
}

//
// Whether the state says a sync is running. Reads under the lock and gives it back before the test checks anything, so that a
// failed check cannot leave the lock held for the destroy that follows.
//
fn isSyncRunning(state: *MainState) bool {
    state.lock();
    defer state.unlock();
    return state.is_sync_running;
}

//
// When the periodic sync is next due, or null.
//
fn periodicDeadline(state: *MainState) ?i64 {
    state.lock();
    defer state.unlock();
    return state.sync_periodic_at;
}

//
// When the debounced sync is due, or null.
//
fn debounceDeadline(state: *MainState) ?i64 {
    state.lock();
    defer state.unlock();
    return state.sync_debounce_at;
}

test "stopPeriodicSync stops the periodic sync, startPeriodicSync starts it, and a second start changes nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    // The state starts the periodic sync when the core starts it.
    try std.testing.expect(periodicDeadline(state) != null);
    state.stopPeriodicSync();
    try std.testing.expect(periodicDeadline(state) == null);
    state.startPeriodicSync();
    const first_deadline = periodicDeadline(state).?;
    app.shell.sleepMs(30);
    state.startPeriodicSync();
    try std.testing.expectEqual(first_deadline, periodicDeadline(state).?);
}

test "scheduleSync called again moves the deadline later, so only the last edit counts" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    state.scheduleSync();
    const first_deadline = debounceDeadline(state).?;
    app.shell.sleepMs(30);
    state.scheduleSync();
    try std.testing.expect(debounceDeadline(state).? > first_deadline);
}

test "enqueueSyncTask queues nothing unless syncing is allowed, a database is open and no sync is running" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    state.lock();
    state.sync_allowed = true;
    state.unlock();
    // No database is open.
    try state.enqueueSyncTask();
    try std.testing.expect(!isSyncRunning(state));
    state.lock();
    try state.setOwned(&state.current_database_path, "/the/open/db");
    state.sync_allowed = false;
    state.unlock();
    // Syncing is not allowed.
    try state.enqueueSyncTask();
    try std.testing.expect(!isSyncRunning(state));
    state.lock();
    state.sync_allowed = true;
    state.is_sync_running = true;
    state.unlock();
    // A sync is running already, so nothing is queued. A sync that was queued would end here (the database has no origin, so the sync is
    // skipped), which would reset the running flag.
    try state.enqueueSyncTask();
    app.shell.sleepMs(100);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("sync-completed"));
    try std.testing.expect(isSyncRunning(state));
    state.lock();
    state.is_sync_running = false;
    state.unlock();
    // Everything allows it, so the sync is queued. The database has no origin, so the sync is skipped, which the page is told, and the
    // end of the task is what resets the running flag.
    try state.enqueueSyncTask();
    try app.shell.expectMessageContaining("\"type\":\"sync-skipped\"");
    try app.shell.expectMessageContaining("no origin configured");
    var waited_ms: u32 = 0;
    while (isSyncRunning(state) and waited_ms < 20_000) : (waited_ms += 5) {
        app.shell.sleepMs(5);
    }
    try std.testing.expect(!isSyncRunning(state));
}

test "resetSyncState to the database that is already open cancels nothing, and to another one cancels its tasks" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "spin", .handler = spinTask }});
    defer app.stop();
    const state = main_state.fromCore(app.core);
    state.lock();
    try state.setOwned(&state.current_database_path, "/the/open/db");
    state.is_sync_running = true;
    state.sync_debounce_at = state.now() + 100_000;
    state.unlock();
    app.core.postMessage("{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"long-1\",\"taskType\":\"spin\",\"source\":\"/the/open/db\",\"data\":null,\"priority\":\"background\"}}");
    try app.shell.expectMessageContaining("\"kind\":\"system\",\"name\":\"task-message\"");
    try state.resetSyncState("/the/open/db");
    app.shell.sleepMs(100);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("\"errorMessage\":\"Cancelled\""));
    try std.testing.expect(!isSyncRunning(state));
    try std.testing.expect(debounceDeadline(state) == null);
    try state.resetSyncState("/another/db");
    try app.shell.expectMessageContaining("\"errorMessage\":\"Cancelled\"");
}

test "a background pass is taken only while it is switched on, due and not running, and the passes are taken separately" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    try std.testing.expect(!state.takeDueBackgroundPass(.import, state.now()));
    state.switchOnBackgroundPass(.import);
    state.switchOnBackgroundPass(.sync);
    try std.testing.expect(state.takeDueBackgroundPass(.import, state.now()));
    try std.testing.expect(!state.takeDueBackgroundPass(.import, state.now()));
    try std.testing.expect(state.takeDueBackgroundPass(.sync, state.now()));
    state.backgroundPassEnded(.import, .{
        .gap_ms = 60_000,
        .finished = false,
    });
    try std.testing.expect(!state.takeDueBackgroundPass(.import, state.now() + 60_000 + 1_000));
    state.releaseBackgroundPass(.import);
    try std.testing.expect(!state.takeDueBackgroundPass(.import, state.now()));
    try std.testing.expect(state.takeDueBackgroundPass(.import, state.now() + 60_000 + 1_000));
    try std.testing.expectEqual(background_work.ReplicaState.unknown, state.prefetch_replica_state.load(.acquire));
}

test "the app is held running while any background work is switched on, and let go when the last of it finishes or is switched off" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    state.switchOnBackgroundPass(.sync);
    state.switchOnBackgroundPass(.prefetch);
    try expectKeepAliveCalls(&app, &[_]bool{true});
    try std.testing.expect(state.takeDueBackgroundPass(.prefetch, state.now()));
    state.backgroundPassEnded(.prefetch, .{
        .gap_ms = 50,
        .finished = true,
    });
    try expectKeepAliveCalls(&app, &[_]bool{true});
    state.switchOffBackgroundPasses();
    try expectKeepAliveCalls(&app, &[_]bool{ true, false });
}

test "a background pass switched on is due at once, and the next is due after the gap the last one asked for" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    const before = state.now();
    state.switchOnBackgroundPass(.prefetch);
    try std.testing.expect(state.background_pass_due_at[prefetch_index].? >= before);
    try std.testing.expect(state.takeDueBackgroundPass(.prefetch, state.now()));
    try std.testing.expect(state.background_pass_due_at[prefetch_index] == null);
    const ended_at = state.now();
    state.backgroundPassEnded(.prefetch, .{
        .gap_ms = 60_000,
        .finished = false,
    });
    try std.testing.expect(state.background_pass_due_at[prefetch_index].? >= ended_at + 60_000);
}

test "a background pass that finishes the work switches it off until it is switched on again" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    state.switchOnBackgroundPass(.prefetch);
    try std.testing.expect(state.takeDueBackgroundPass(.prefetch, state.now()));
    state.backgroundPassEnded(.prefetch, .{
        .gap_ms = 60_000,
        .finished = true,
    });
    state.releaseBackgroundPass(.prefetch);
    try std.testing.expect(!state.background_passes_on[prefetch_index]);
    try std.testing.expect(state.background_pass_due_at[prefetch_index] == null);
    try std.testing.expect(!state.takeDueBackgroundPass(.prefetch, state.now()));
    state.switchOnBackgroundPass(.prefetch);
    try std.testing.expect(state.takeDueBackgroundPass(.prefetch, state.now()));
}

test "switching the background work off leaves nothing due, even when a pass in flight ends afterwards" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    state.switchOnBackgroundPass(.sync);
    try std.testing.expect(state.takeDueBackgroundPass(.sync, state.now()));
    state.switchOffBackgroundPasses();
    state.backgroundPassEnded(.sync, .{
        .gap_ms = 10,
        .finished = false,
    });
    try std.testing.expect(state.background_pass_due_at[sync_index] == null);
    try std.testing.expect(!state.background_passes_on[sync_index]);
}

test "only the first sync pass after the sync is switched on is the first" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const state = main_state.fromCore(app.core);
    stopTimerThread(state);

    state.switchOnBackgroundPass(.sync);
    try std.testing.expect(state.takeFirstSyncPass());
    try std.testing.expect(!state.takeFirstSyncPass());
    state.switchOnBackgroundPass(.sync);
    try std.testing.expect(!state.takeFirstSyncPass());
}
