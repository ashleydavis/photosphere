//
// The rule that only one copy of the packaged desktop app runs at a time. The first copy takes a lock on a file in the app's data
// directory and keeps it for as long as it runs; the operating system releases the lock when the process ends in any way, so a copy that
// crashed never leaves the app locked out. A second copy that cannot take the lock leaves a signal file beside it and quits, and the
// first copy looks for the file on its timer, removes it and brings its window to the front.
//
// The rule does not apply to a build that has no version (the copies a developer runs side by side), to a test (each test runs its own
// copy) or to a phone (its operating system runs one copy).
//

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config-zig");
const storage = @import("storage-zig");
const test_mode = @import("test-mode.zig");

//
// The name of the file that is locked, in the data directory.
//
const LOCK_FILE_NAME = "single-instance.lock";

//
// The name of the file a second copy leaves to tell the first copy it was started, in the data directory.
//
const SIGNAL_FILE_NAME = "single-instance.signal";

//
// A copy of the app that holds the lock.
//
pub const SingleInstance = struct {
    // Allocates the path of the signal file.
    allocator: std.mem.Allocator,

    // The locked file. The lock is held while it is open.
    lock_file: std.Io.File,

    // The path of the signal file. Owned.
    signal_path: []u8,

    //
    // Looks for the signal a second copy leaves, and removes it. Returns true when a second copy was started since the last call.
    //
    pub fn takeSignal(self: *SingleInstance, io: std.Io) !bool {
        std.Io.Dir.cwd().deleteFile(io, self.signal_path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    //
    // Lets go of the lock, so that another copy can take it, and frees what the value holds.
    //
    pub fn release(self: *SingleInstance, io: std.Io) void {
        self.lock_file.close(io);
        self.allocator.free(self.signal_path);
    }
};

//
// What taking the lock came to.
//
pub const Acquisition = union(enum) {
    // This copy holds the lock and is the one that runs.
    acquired: SingleInstance,

    // Another copy holds the lock. It has been told this copy was started, and this copy must quit.
    denied,
};

//
// Whether the rule applies to this copy: the app is packaged (it has been given a version), it is not a test, and it is not a phone.
//
pub fn ruleApplies() bool {
    if (builtin.os.tag == .ios or builtin.abi.isAndroid()) {
        return false;
    }
    if (test_mode.isTestMode()) {
        return false;
    }
    return !isUnpackaged();
}

//
// Whether this build has no version, as a build run from the source tree has none.
//
pub fn isUnpackaged() bool {
    return std.mem.eql(u8, config.version, "dev");
}

//
// Takes the lock in the data directory, or tells the copy that holds it that this one was started. The directory is made when it does not
// exist.
//
pub fn acquire(allocator: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Acquisition {
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    const lock_path = try std.fs.path.join(allocator, &.{ data_dir, LOCK_FILE_NAME });
    defer allocator.free(lock_path);
    const signal_path = try std.fs.path.join(allocator, &.{ data_dir, SIGNAL_FILE_NAME });
    errdefer allocator.free(signal_path);

    const lock_file = try std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
    });
    errdefer lock_file.close(io);
    if (!try lock_file.tryLock(io, .exclusive)) {
        const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{storage.storage.processId()});
        defer allocator.free(pid_text);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = signal_path,
            .data = pid_text,
        });
        lock_file.close(io);
        allocator.free(signal_path);
        return .denied;
    }
    return .{
        .acquired = .{
            .allocator = allocator,
            .lock_file = lock_file,
            .signal_path = signal_path,
        },
    };
}
