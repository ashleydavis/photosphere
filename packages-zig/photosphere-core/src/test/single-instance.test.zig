//
// Tests for single-instance.zig and the parts of main-state.zig that apply the rule.
//
// The lock is a real file lock, so these tests take it twice in one process: the operating system refuses the second lock on a second
// handle to the same file whichever process asks for it, which is what stops a second copy of the app.
//

const std = @import("std");
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

    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "Single instance lock acquired (pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "packaged=false)") != null);
    try std.testing.expect(!app.shell.quit_called.load(.acquire));
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

    try main_state.fromCore(app.core).enforceSingleInstance(true);

    try std.testing.expect(app.shell.quit_called.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "Single instance lock denied (pid=") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "); quitting") != null);
    try std.testing.expect(main_state.fromCore(app.core).single_instance == null);
}

test "a copy that takes the lock keeps it until the core is destroyed" {
    var app: TestApp = undefined;
    try app.start();
    const state = main_state.fromCore(app.core);

    try state.enforceSingleInstance(true);
    try std.testing.expect(state.single_instance != null);
    try std.testing.expect(!app.shell.quit_called.load(.acquire));
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
    const state = main_state.fromCore(app.core);
    try state.enforceSingleInstance(true);
    // The timer would look for the signal too, and this test looks for it itself.
    state.lock();
    state.single_instance_check_at = null;
    state.unlock();

    try state.checkSecondInstance();
    try std.testing.expectEqual(@as(usize, 0), app.shell.chosen_actions.items.len);
    const second = try single_instance.acquire(std.testing.allocator, io, app.tmp_path);
    try std.testing.expect(second == .denied);
    try state.checkSecondInstance();

    try std.testing.expectEqualStrings("focus-window\n", app.shell.chosen_actions.items);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "Second-instance signal received by pid=") != null);
}

test "a copy that holds no lock has no second copy to look for" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    try main_state.fromCore(app.core).checkSecondInstance();

    try std.testing.expectEqual(@as(usize, 0), app.shell.chosen_actions.items.len);
}
