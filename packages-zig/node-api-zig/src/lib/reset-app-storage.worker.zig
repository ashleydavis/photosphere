//
// Reset-app-storage worker handler.
//
// Empties the two directories the app keeps its own files in: the config directory (the databases
// list, the desktop settings, the automatic-import and sync settings, the news state) and the cache
// directory (the hash caches and the import records). The directories themselves are left in place,
// so the app writes into them again exactly as it did on a fresh install.
//
// This is what "reset device" deletes. On desktop those two are the config and cache directories
// under the user's home, which hold only the app's own files, so a database at a path the user chose
// is left exactly where it is.
//
// On a phone every database the app created sits in the app's data directory, which only the app's
// shell knows. On Android that is the home directory, which getCacheDir() answers there, but on iOS
// it is the app's Application Support directory, which neither getConfigDir() nor getCacheDir()
// answers. So the Photosphere App's core runs resetAppStorage itself on a phone, naming its data
// directory as the third directory to empty, and that is what takes the databases off the device.
//
// The handler takes no input naming a path, deliberately. A task that accepted "delete this
// directory" would be one bad caller away from deleting somebody's photo library, and nothing in the
// type system would catch it. The only paths it can ever reach are the two it reads for itself, and
// the data directory a phone's core passes in from its own configuration.
//
// Runs on every platform via the shared task queue: the app's core and the CLI register it through
// task-handlers.zig. On a phone the deletes go straight to the filesystem, so the directories named
// here are the only boundary.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const Timers = @import("ziggy").timers.Timers;
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
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
    // The directories that were emptied, each once: the config and the cache directory, and on a
    // phone the app's data directory, fewer when any of them are the same place.
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
// Empties the app's config and cache directories, and the device's data directory when one is
// given, and reports what it removed. Each directory is emptied once, however many of them name it.
// deviceDataDir is the app's data directory on a phone, where every database the app made sits, and
// null everywhere else: on desktop the data directory holds the default database, which is the
// user's photos and must survive a reset.
//
pub fn resetAppStorage(allocator: std.mem.Allocator, io: std.Io, deviceDataDir: ?[]const u8) !IResetAppStorageResult {
    var candidatePaths: std.ArrayList([]const u8) = .empty;
    try candidatePaths.append(allocator, try getConfigDir(allocator));
    try candidatePaths.append(allocator, try getCacheDir(allocator));
    if (deviceDataDir) |dataDir| {
        try candidatePaths.append(allocator, dataDir);
    }

    // Deduplicated because on Android the config, the cache and the data directory can all be the
    // storage sandbox root. Emptying the same directory twice would count everything in it once and
    // then find nothing, reporting a number that does not match what went.
    var directoryPaths: std.ArrayList([]const u8) = .empty;
    for (candidatePaths.items) |directoryPath| {
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

    return .{
        .directoriesCleared = directoryPaths.items,
        .entriesRemoved = entriesRemoved,
    };
}

//
// Handler for the reset-app-storage task. Empties the app's config and cache directories and reports
// what it removed. It names no data directory, so on desktop and in the CLI the data directory is
// left alone; the Photosphere App's core answers this task type itself on a phone (see resetAppStorage).
// (Zig: the task data is a JSON value that is ignored, and the output is a JSON value holding IResetAppStorageResult.
// The context is ignored.)
//
pub fn resetAppStorageHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    log: ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = log;
    _ = taskData;
    _ = context;

    const result = try resetAppStorage(allocator, io, null);
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
