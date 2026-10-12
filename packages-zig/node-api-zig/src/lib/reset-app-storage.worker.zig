//
// Reset-app-storage worker handler.
//
// Empties the two directories the app keeps its own files in: the config directory (the databases
// list, the desktop settings, the automatic-import and sync settings, the news state) and the cache
// directory (the hash caches and the import records). The directories themselves are left in place,
// so the app writes into them again exactly as it did on a fresh install.
//
// This is what "reset device" deletes, and on a phone it is what removes the databases: a local
// database path on mobile is a name inside the app's storage sandbox, and getConfigDir() and
// getCacheDir() both answer that sandbox root there, so every database the app created goes with it.
// On desktop those two are the config and cache directories under the user's home, which hold only
// the app's own files, so a database at a path the user chose is left exactly where it is.
//
// The handler takes no input naming a path, deliberately. A task that accepted "delete this
// directory" would be one bad caller away from deleting somebody's photo library, and nothing in the
// type system would catch it. The only paths it can ever reach are the two it reads for itself.
//
// Runs on every platform via the shared task queue: the app's core and the CLI register it through
// initTaskHandlers. On a phone the deletes go straight to the filesystem, so the two directories
// getConfigDir() and getCacheDir() answer are the only boundary.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const getConfigDir = node_utils.fs.getConfigDir;
const getCacheDir = node_utils.fs.getCacheDir;
const pathExists = node_utils.fs.pathExists;
const remove = node_utils.fs.remove;
const readdir = node_utils.node_fs.readdir;

//
// Result of the reset-app-storage task.
//
pub const IResetAppStorageResult = struct {
    //
    // The directories that were emptied. One entry on a device, where the config and the cache are
    // both the app's storage sandbox; two on desktop.
    //
    directoriesCleared: []const []const u8,

    //
    // How many entries (files and directory trees) were removed across those directories.
    //
    entriesRemoved: u64,
};

//
// Empties one directory, returning how many entries it removed. A directory that does not exist has
// nothing to remove and is not an error: an app that has never written a cache still resets.
//
fn clearDirectory(allocator: std.mem.Allocator, io: std.Io, directoryPath: []const u8) !u64 {
    if (!pathExists(io, directoryPath)) {
        return 0;
    }

    const entryNames = try readdir(allocator, io, directoryPath);
    for (entryNames) |entryName| {
        try remove(io, try node_utils.path.join(allocator, &.{ directoryPath, entryName }));
    }
    return entryNames.len;
}

//
// Handler for the reset-app-storage task. Empties the app's config and cache directories and reports
// what it removed.
// (Zig: the task data is a JSON value that is ignored, and the output is a JSON value holding IResetAppStorageResult.
// The context is ignored.)
//
pub fn resetAppStorageHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = taskData;
    _ = context;

    // Deduplicated because on a device both answer the storage sandbox root. Emptying the same
    // directory twice would count everything in it once and then find nothing, reporting a number
    // that does not match what went.
    var directoryPaths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ try getConfigDir(allocator), try getCacheDir(allocator) }) |directoryPath| {
        const normalized = try node_utils.path.normalize(allocator, directoryPath);
        var alreadyIncluded = false;
        for (directoryPaths.items) |includedPath| {
            if (std.mem.eql(u8, includedPath, normalized)) {
                alreadyIncluded = true;
            }
        }
        if (!alreadyIncluded) {
            try directoryPaths.append(allocator, normalized);
        }
    }

    var entriesRemoved: u64 = 0;
    for (directoryPaths.items) |directoryPath| {
        entriesRemoved += try clearDirectory(allocator, io, directoryPath);
    }

    const result: IResetAppStorageResult = .{
        .directoriesCleared = directoryPaths.items,
        .entriesRemoved = entriesRemoved,
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
