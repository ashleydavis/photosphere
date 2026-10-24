//
// Tests for single-instance.zig and the parts of main-state.zig that apply the rule.
//
// The lock is a real file lock, so these tests take it twice in one process: the operating system refuses the second lock on a second
// handle to the same file whichever process asks for it, which is what stops a second copy of the app.
//

const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const single_instance = @import("photosphere-core").single_instance;

const TestApp = support.TestApp;
const io = std.testing.io;

//
// Makes a folder that belongs to the test and returns its path. The caller frees it.
//
fn dataDirectory(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const current_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current_path);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "the first copy takes the lock and a second copy is turned away" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try dataDirectory(&tmp, "data");
    defer std.testing.allocator.free(directory);

    var first = switch (try single_instance.acquire(std.testing.allocator, io, directory)) {
        .acquired => |instance| instance,
        .denied => return error.FirstCopyWasTurnedAway,
    };
    defer first.release(io);
    const second = try single_instance.acquire(std.testing.allocator, io, directory);

    try std.testing.expect(second == .denied);
}

test "a copy that is turned away leaves a signal the first copy takes once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try dataDirectory(&tmp, "data");
    defer std.testing.allocator.free(directory);
    var first = switch (try single_instance.acquire(std.testing.allocator, io, directory)) {
        .acquired => |instance| instance,
        .denied => return error.FirstCopyWasTurnedAway,
    };
    defer first.release(io);

    try std.testing.expect(!try first.takeSignal(io));
    _ = try single_instance.acquire(std.testing.allocator, io, directory);
    try std.testing.expect(try first.takeSignal(io));
    try std.testing.expect(!try first.takeSignal(io));
}

test "the lock can be taken again once the first copy lets go of it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try dataDirectory(&tmp, "data");
    defer std.testing.allocator.free(directory);
    var first = switch (try single_instance.acquire(std.testing.allocator, io, directory)) {
        .acquired => |instance| instance,
        .denied => return error.FirstCopyWasTurnedAway,
    };
    first.release(io);

    var again = switch (try single_instance.acquire(std.testing.allocator, io, directory)) {
        .acquired => |instance| instance,
        .denied => return error.LockWasNotReleased,
    };
    again.release(io);
}

test "the data directory is made when it does not exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try dataDirectory(&tmp, "a/b/data");
    defer std.testing.allocator.free(directory);

    var first = switch (try single_instance.acquire(std.testing.allocator, io, directory)) {
        .acquired => |instance| instance,
        .denied => return error.FirstCopyWasTurnedAway,
    };
    first.release(io);

    try tmp.dir.access(io, "a/b/data/single-instance.lock", .{});
}

test "the rule does not apply to a build that has no version, which is the build under test" {
    try std.testing.expect(single_instance.isUnpackaged());
    try std.testing.expect(!single_instance.ruleApplies());
}

test "a core logs that it has the lock when the rule does not apply to it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Single instance lock acquired (pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "packaged=false)") != null);
    try std.testing.expect(!app.native_app.quitCalled(std.testing.io, std.testing.allocator));
}

test "a copy that cannot take the lock logs it and asks the shell to quit" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var holder = switch (try single_instance.acquire(std.testing.allocator, io, app.tmp_path)) {
        .acquired => |instance| instance,
        .denied => return error.FirstCopyWasTurnedAway,
    };
    defer holder.release(io);

    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.enforceSingleInstance(services, timers, main_io, main_state.stateAllocator(), true);
            try std.testing.expect(state.single_instance == null);
        }
    }.check);

    try std.testing.expect(app.native_app.quitCalled(std.testing.io, std.testing.allocator));
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Single instance lock denied (pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "); quitting") != null);
}

test "a copy that takes the lock keeps it until the core is destroyed" {
    var app: TestApp = undefined;
    try app.start();

    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.enforceSingleInstance(services, timers, main_io, main_state.stateAllocator(), true);
            try std.testing.expect(state.single_instance != null);
        }
    }.check);
    try std.testing.expect(!app.native_app.quitCalled(std.testing.io, std.testing.allocator));
    const second = try single_instance.acquire(std.testing.allocator, io, app.tmp_path);
    try std.testing.expect(second == .denied);
    app.stopCore();
    defer app.stop();

    var after = switch (try single_instance.acquire(std.testing.allocator, io, app.tmp_path)) {
        .acquired => |instance| instance,
        .denied => return error.LockWasNotReleasedByTheCore,
    };
    after.release(io);
}

test "the first copy brings its window to the front when a second copy was started" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const CheckForSecond = struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.checkSecondInstance(services, main_io, main_state.stateAllocator());
        }
    };
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.enforceSingleInstance(services, timers, main_io, main_state.stateAllocator(), true);
            // The timer would look for the signal too, and this test looks for it itself.
            if (state.single_instance_timer) |timer| {
                timers.clearInterval(timer);
                state.single_instance_timer = null;
            }
        }
    }.check);

    try app.onState(@as(u8, 0), CheckForSecond.check);
    const actions_before = try app.native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions_before);
    try std.testing.expectEqual(@as(usize, 0), actions_before.len);
    const second = try single_instance.acquire(std.testing.allocator, io, app.tmp_path);
    try std.testing.expect(second == .denied);
    try app.onState(@as(u8, 0), CheckForSecond.check);

    const actions = try app.native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions);
    try std.testing.expectEqualStrings("focus-window\n", actions);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "Second-instance signal received by pid=") != null);
}

test "a copy that holds no lock has no second copy to look for" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, state: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io) anyerror!void {
            try state.checkSecondInstance(services, main_io, main_state.stateAllocator());
        }
    }.check);

    const actions_before = try app.native_app.chosenActions(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(actions_before);
    try std.testing.expectEqual(@as(usize, 0), actions_before.len);
}
