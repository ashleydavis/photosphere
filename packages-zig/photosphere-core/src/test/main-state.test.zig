const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const background_work = @import("photosphere-core").background_work;

const MainState = main_state.MainState;
const TestApp = support.TestApp;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const TimerId = ziggy.timers.TimerId;

//
// The state belongs to the core's main thread, so every test reads and changes it from a function the test app runs there
// (TestApp.onMainThread).
//

// Where the sync pass is in the state's arrays, which are indexed by pass.
const sync_index = @intFromEnum(background_work.Pass.sync);

// Where the import pass is in the state's arrays.
const import_index = @intFromEnum(background_work.Pass.import);

// Where the prefetch pass is in the state's arrays.
const prefetch_index = @intFromEnum(background_work.Pass.prefetch);

//
// Waits until the native app has been told as many keep-alive changes as are expected, and checks they are the ones expected.
//
fn expectKeepAliveCalls(app: *TestApp, expected: []const bool) !void {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var calls: []const bool = &.{};
    var waited_ms: u32 = 0;
    while (waited_ms < 2_000) : (waited_ms += 1) {
        calls = try std.json.parseFromSliceLeaky([]const bool, allocator, try app.native_app.keepAliveCalls(io, allocator), .{});
        if (calls.len >= expected.len) {
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqualSlices(bool, expected, calls);
}

//
// The main thread's timers, which Ziggy gives every handler as the Timers interface of its TimerList. Called on the main thread.
//
fn timerList(timers: Timers) *ziggy.timers.TimerList {
    return @ptrCast(@alignCast(timers.ptr));
}

//
// How many milliseconds are left before the main thread's timer is due, or null when it is not set. Called on the main thread.
//
fn msUntilDue(timers: Timers, main_io: std.Io, id: TimerId) ?i64 {
    const list = timerList(timers);
    for (list.timers[0..list.count]) |timer| {
        if (timer.id == id) {
            return @intCast(@divTrunc(timer.due.durationFromNow(main_io).raw.nanoseconds, std.time.ns_per_ms));
        }
    }
    return null;
}

//
// Handler services that count the tasks queued and queue none, given to the state for a call that must queue nothing. Any other call
// fails the test, since the call was not expected to make it.
//
const CountedServices = struct {
    // How many tasks were queued.
    added: usize = 0,

    const vtable: HandlerServices.VTable = .{
        .sendEvent = sendEvent,
        .addTask = addTask,
        .cancelTasks = cancelTasks,
        .holdKeepAlive = holdKeepAlive,
        .quit = quit,
        .menuAction = menuAction,
        .dataDir = dataDir,
        .isPhone = isPhone,
        .nativeCallbacks = nativeCallbacks,
        .configureLog = configureLog,
    };

    fn interface(self: *CountedServices) HandlerServices {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .log = ziggy.log.mute_log.MuteLog.init(),
        };
    }

    fn of(ptr: *anyopaque) *CountedServices {
        return @ptrCast(@alignCast(ptr));
    }

    fn unexpected(comptime name: []const u8) noreturn {
        @panic("the state called " ++ name ++ " on services that only count the tasks queued");
    }

    fn sendEvent(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) anyerror!void {
        unexpected("sendEvent");
    }

    fn addTask(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: ziggy.task_runner.TaskPriority) anyerror!void {
        of(ptr).added += 1;
    }

    fn cancelTasks(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) void {
        unexpected("cancelTasks");
    }

    fn holdKeepAlive(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: bool) void {
        unexpected("holdKeepAlive");
    }

    fn quit(_: *anyopaque, _: std.Io, _: std.mem.Allocator) void {
        unexpected("quit");
    }

    fn menuAction(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) void {
        unexpected("menuAction");
    }

    fn dataDir(_: *anyopaque) []const u8 {
        unexpected("dataDir");
    }

    fn isPhone(_: *anyopaque) bool {
        unexpected("isPhone");
    }

    fn configureLog(_: *anyopaque, _: ziggy.log.ILogOptions) anyerror!void {
        unexpected("configureLog");
    }

    fn nativeCallbacks(_: *anyopaque) ziggy.core.NativeCallbacks {
        unexpected("nativeCallbacks");
    }
};

//
// A task that sends an event and then runs until it is cancelled.
//
fn spinTask(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    _ = data;
    try services.sendEvent(io, allocator, .{ .spinning = true });
    while (true) {
        try services.checkCancelled(io, allocator);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

//
// Reads whether a sync is running, on the main thread.
//
fn readSyncRunning(_: u8, _: HandlerServices, _: Timers, _: std.Io, _: std.mem.Allocator) anyerror!bool {
    return main_state.current().is_sync_running;
}

//
// Whether the state records a sync as running.
//
fn isSyncRunning(app: *TestApp) !bool {
    return try app.onMainThread(@as(u8, 0), readSyncRunning);
}

test "stopPeriodicSync stops the periodic sync, startPeriodicSync starts it, and a second start changes nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, _: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            // The state starts the periodic sync when the core starts it.
            try std.testing.expect(state.sync_periodic_timer != null);
            state.stopPeriodicSync(timers);
            try std.testing.expect(state.sync_periodic_timer == null);
            try state.startPeriodicSync(timers, main_io);
            const first = state.sync_periodic_timer.?;
            try std.testing.expect(timers.isSet(first));
            try state.startPeriodicSync(timers, main_io);
            try std.testing.expectEqual(first, state.sync_periodic_timer.?);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "scheduleSync called again replaces the debounce timer, so only the last edit counts" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const log = services.log;
            const state = main_state.current();
            try state.scheduleSync(timers, main_io, log);
            const first = state.sync_debounce_timer.?;
            try state.scheduleSync(timers, main_io, log);
            const second = state.sync_debounce_timer.?;
            try std.testing.expect(first != second);
            try std.testing.expect(!timers.isSet(first));
            try std.testing.expect(msUntilDue(timers, main_io, second).? > @as(i64, @intCast(state.sync_debounce_ms)) - 1_000);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "enqueueSyncTask queues nothing unless syncing is allowed, a database is open and no sync is running" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Refused = struct {
        fn run(_: u8, services: HandlerServices, _: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.sync_allowed = true;
            // No database is open.
            try state.enqueueSyncTask(services, main_io, main_state.stateAllocator());
            try std.testing.expect(!state.is_sync_running);
            try main_state.setOwned(main_state.stateAllocator(), &state.current_database_path, "/the/open/db");
            state.sync_allowed = false;
            // Syncing is not allowed.
            try state.enqueueSyncTask(services, main_io, main_state.stateAllocator());
            try std.testing.expect(!state.is_sync_running);
            state.sync_allowed = true;
            state.is_sync_running = true;
            // A sync is running already, so nothing is queued. A sync that was queued would end here (the database has no origin, so
            // the sync is skipped), which would reset the running flag.
            try state.enqueueSyncTask(services, main_io, main_state.stateAllocator());
        }
    };
    try app.onMainThread(@as(u8, 0), Refused.run);
    ziggy.fake_native_app.sleepMs(std.testing.io, 100);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "sync-completed"));
    try std.testing.expect(try isSyncRunning(&app));

    const Queued = struct {
        fn run(_: u8, services: HandlerServices, _: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.is_sync_running = false;
            // Everything allows it, so the sync is queued.
            try state.enqueueSyncTask(services, main_io, main_state.stateAllocator());
            try std.testing.expect(state.is_sync_running);
        }
    };
    try app.onMainThread(@as(u8, 0), Queued.run);
    // The database has no origin, so the sync is skipped, which the page is told, and the end of the task is what resets the running
    // flag.
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"type\":\"sync-skipped\"");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "no origin configured");
    var waited_ms: u32 = 0;
    while ((try isSyncRunning(&app)) and waited_ms < 20_000) : (waited_ms += 5) {
        ziggy.fake_native_app.sleepMs(std.testing.io, 5);
    }
    try std.testing.expect(!try isSyncRunning(&app));
}

test "resetSyncState to the database that is already open cancels nothing, and to another one cancels its tasks" {
    var app: TestApp = undefined;
    try app.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{.{ .name = "spin", .handler = spinTask }});
    defer app.stop();
    const Open = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const log = services.log;
            const state = main_state.current();
            try main_state.setOwned(main_state.stateAllocator(), &state.current_database_path, "/the/open/db");
            state.is_sync_running = true;
            try state.scheduleSync(timers, main_io, log);
        }
    };
    try app.onMainThread(@as(u8, 0), Open.run);
    app.native_app.sendMessage(std.testing.allocator, "{\"kind\":\"system\",\"name\":\"add-task\",\"data\":{\"taskId\":\"long-1\",\"taskType\":\"spin\",\"source\":\"/the/open/db\",\"data\":null,\"priority\":\"background\"}}");
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"kind\":\"system\",\"name\":\"task-event\"");

    const ResetToSame = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.resetSyncState(services, timers, main_io, main_state.stateAllocator(), "/the/open/db");
            try std.testing.expect(!state.is_sync_running);
            try std.testing.expect(state.sync_debounce_timer == null);
        }
    };
    try app.onMainThread(@as(u8, 0), ResetToSame.run);
    ziggy.fake_native_app.sleepMs(std.testing.io, 100);
    try std.testing.expectEqual(@as(usize, 0), app.native_app.countContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"Cancelled\""));

    const ResetToAnother = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            main_state.current().resetSyncState(services, timers, main_io, main_state.stateAllocator(), "/another/db");
        }
    };
    try app.onMainThread(@as(u8, 0), ResetToAnother.run);
    try app.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, "\"errorMessage\":\"Cancelled\"");
}

test "a background pass is queued only while it is switched on and not running, and the passes are queued separately" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            // Switched off, so nothing is queued.
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .import);
            try std.testing.expect(!state.background_passes_running[import_index]);
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .import);
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .import);
            try std.testing.expect(state.background_passes_running[import_index]);
            try std.testing.expect(!state.background_passes_running[sync_index]);
            // Running already, so it is not queued again: its end below is the only one.
            var counted: CountedServices = .{};
            state.queueDueBackgroundPass(counted.interface(), timers, main_io, main_state.stateAllocator(), .import);
            try std.testing.expectEqual(@as(usize, 0), counted.added);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            try std.testing.expect(state.background_passes_running[sync_index]);
            state.backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .import, .{
                .gapMs = 60_000,
                .finished = false,
                .replicaState = .unknown,
            });
            try std.testing.expect(!state.background_passes_running[import_index]);
            try std.testing.expect(state.background_passes_on[import_index]);
            try std.testing.expectEqual(background_work.ReplicaState.unknown, state.prefetch_replica_state);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "the app is held running while any background work is switched on, and let go when the last of it finishes or is switched off" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const SwitchOn = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
        }
    };
    try app.onMainThread(@as(u8, 0), SwitchOn.run);
    try expectKeepAliveCalls(&app, &[_]bool{true});
    const PrefetchFinishes = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            main_state.current().backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .prefetch, .{
                .gapMs = 50,
                .finished = true,
                .replicaState = .complete,
            });
        }
    };
    try app.onMainThread(@as(u8, 0), PrefetchFinishes.run);
    try expectKeepAliveCalls(&app, &[_]bool{true});
    const SwitchOff = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            main_state.current().switchOffBackgroundPasses(services, timers, main_io, main_state.stateAllocator());
        }
    };
    try app.onMainThread(@as(u8, 0), SwitchOff.run);
    try expectKeepAliveCalls(&app, &[_]bool{ true, false });
}

test "a background pass switched on is due at once, and the next is due after the gap the last one asked for" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            try std.testing.expect(msUntilDue(timers, main_io, state.background_pass_timers[prefetch_index].?).? <= 0);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            try std.testing.expect(state.background_pass_timers[prefetch_index] == null);
            state.backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .prefetch, .{
                .gapMs = 60_000,
                .finished = false,
                .replicaState = .working,
            });
            try std.testing.expect(msUntilDue(timers, main_io, state.background_pass_timers[prefetch_index].?).? > 59_000);
            try std.testing.expectEqual(background_work.ReplicaState.working, state.prefetch_replica_state);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "a background pass that finishes the work switches it off until it is switched on again" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            state.backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .prefetch, .{
                .gapMs = 60_000,
                .finished = true,
                .replicaState = .complete,
            });
            try std.testing.expect(!state.background_passes_on[prefetch_index]);
            try std.testing.expect(state.background_pass_timers[prefetch_index] == null);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            try std.testing.expect(!state.background_passes_running[prefetch_index]);
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .prefetch);
            try std.testing.expect(state.background_passes_on[prefetch_index]);
            try std.testing.expect(state.background_pass_timers[prefetch_index] != null);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "switching the background work off leaves nothing due, even when a pass in flight ends afterwards" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            state.switchOffBackgroundPasses(services, timers, main_io, main_state.stateAllocator());
            state.backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .sync, .{
                .gapMs = 10,
                .finished = false,
                .replicaState = .unknown,
            });
            try std.testing.expect(state.background_pass_timers[sync_index] == null);
            try std.testing.expect(!state.background_passes_on[sync_index]);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "only the first sync pass after the sync is switched on is the first" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const Check = struct {
        fn run(_: u8, services: HandlerServices, timers: Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!void {
            const state = main_state.current();
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            try std.testing.expect(state.first_sync_pass);
            state.queueDueBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            try std.testing.expect(!state.first_sync_pass);
            state.backgroundPassEnded(services, timers, main_io, main_state.stateAllocator(), .sync, null);
            // Switching on a pass that is on changes nothing.
            state.switchOnBackgroundPass(services, timers, main_io, main_state.stateAllocator(), .sync);
            try std.testing.expect(!state.first_sync_pass);
        }
    };
    try app.onMainThread(@as(u8, 0), Check.run);
}

test "no log option on the app's command line turns on no lines" {
    const options = main_state.logOptions(&.{"-geometry=800x600"});
    try std.testing.expect(!options.verbose);
    try std.testing.expect(!options.debug);
    try std.testing.expect(!options.tools);
}

test "--verbose, --debug and --tools on the app's command line each turn on their lines" {
    const verbose = main_state.logOptions(&.{"--verbose"});
    try std.testing.expect(verbose.verbose);
    try std.testing.expect(!verbose.debug);
    try std.testing.expect(!verbose.tools);
    const all = main_state.logOptions(&.{ "--tools", "-geometry=800x600", "--debug", "--verbose" });
    try std.testing.expect(all.verbose);
    try std.testing.expect(all.debug);
    try std.testing.expect(all.tools);
}
