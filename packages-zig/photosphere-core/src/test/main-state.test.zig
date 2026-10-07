const std = @import("std");
const ziggy = @import("ziggy-core");
const support = @import("test-support.zig");
const main_state = @import("../lib/main-state.zig");

const MainState = main_state.MainState;
const TestApp = support.TestApp;

//
// A task that sends a message and then runs until it is cancelled.
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
    // A sync is running already, so nothing is queued. A sync that was queued would fail here (no sync task type is registered in this
    // core), which would tell the page that it completed and reset the running flag.
    try state.enqueueSyncTask();
    app.shell.sleepMs(100);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("sync-completed"));
    try std.testing.expect(isSyncRunning(state));
    state.lock();
    state.is_sync_running = false;
    state.unlock();
    // Everything allows it, so the sync is queued. That one fails for want of a task type, which is how its end is seen.
    try state.enqueueSyncTask();
    try app.shell.expectMessageContaining("{\"channel\":\"sync-completed\",\"data\":null}");
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
    app.core.postMessage("{\"channel\":\"add-task\",\"data\":{\"taskId\":\"long-1\",\"taskType\":\"spin\",\"source\":\"/the/open/db\",\"data\":null,\"priority\":0}}");
    try app.shell.expectMessageContaining("\"channel\":\"task-message\"");
    try state.resetSyncState("/the/open/db");
    app.shell.sleepMs(100);
    try std.testing.expectEqual(@as(usize, 0), app.shell.countContaining("\"status\":\"cancelled\""));
    try std.testing.expect(!isSyncRunning(state));
    try std.testing.expect(debounceDeadline(state) == null);
    try state.resetSyncState("/another/db");
    try app.shell.expectMessageContaining("\"status\":\"cancelled\"");
}
