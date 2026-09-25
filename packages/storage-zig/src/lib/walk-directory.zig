const std = @import("std");
const utils = @import("utils-zig");
const storage_module = @import("storage.zig");
const storage_factory = @import("storage-factory.zig");

const log = utils.log;
const retry = utils.retry.retry;
const IStorage = storage_module.IStorage;
const IListResult = storage_module.IListResult;
const pathJoin = storage_factory.pathJoin;

//
// How long one page of a directory listing is allowed to take, in milliseconds.
//
// `retry`'s default of thirty seconds was what applied, and a walk of a real database's index
// directories failed on it: measured on a Pixel 6 filling in a partial replica of an 8,231-photo
// database, a pass ran for 35 minutes 30 seconds, fetched 8,231 thumbnails and 106 of the 116
// missing index files, and then ended on "Operation timed out after 30000ms: () =>
// storage.listDirs(dirPath, 1000, next)".
//
// The listing was not slow. The walk runs interleaved with the copies it feeds, and on the phone
// those copies block the embedded engine's thread inside synchronous host calls: the failing task
// reported 193 seconds of run time with 81 milliseconds of pumping and 14 of waiting for events, so
// for most of those three minutes no JavaScript ran at all. A wall-clock timeout then measures time
// the listing was never given, and all three of `retry`'s attempts expired inside the same 80
// milliseconds, one after another, without the listing having had a chance between them.
//
// So this is slack for an engine that stops running JavaScript while it moves bytes, not an estimate
// of how long a listing takes. It is minutes rather than the ninety of LARGE_FILE_TIMEOUT because a
// listing that genuinely never answers should still be given up on inside a pass rather than holding
// one open for an hour and a half.
//
const DIRECTORY_LISTING_TIMEOUT = 5 * 60 * 1_000;

//
// Represents a file that has been ordered by where it was found in the file system.
//
pub const IOrderedFile = struct {
    // The path of the file (the directory path joined with the file name).
    fileName: []const u8,
};

//
// A pattern that paths are tested against (TypeScript: a RegExp and `pattern.test(fullPath)`).
// Zig has no regular expressions, so each pattern is a function that returns true when the path matches.
//
pub const IgnorePattern = *const fn (fullPath: []const u8) bool;

//
// Matches /node_modules/.
//
pub fn matchesNodeModules(fullPath: []const u8) bool {
    return std.mem.indexOf(u8, fullPath, "node_modules") != null;
}

//
// Matches /\.git/.
//
pub fn matchesGit(fullPath: []const u8) bool {
    return std.mem.indexOf(u8, fullPath, ".git") != null;
}

//
// Matches /\.DS_Store/.
//
pub fn matchesDsStore(fullPath: []const u8) bool {
    return std.mem.indexOf(u8, fullPath, ".DS_Store") != null;
}

//
// The default ignore patterns: [/node_modules/, /\.git/, /\.DS_Store/].
//
pub const default_ignore_patterns = [_]IgnorePattern{ matchesNodeModules, matchesGit, matchesDsStore };

//
// The retried file listing (TypeScript: `() => storage.listFiles(dirPath, 1000, next)`).
//
const ListFilesOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => storage.listFiles(dirPath, 1000, next)";

    // The storage to list.
    storage: IStorage,

    // Allocates the result.
    allocator: std.mem.Allocator,

    // The directory to list.
    dirPath: []const u8,

    // The continuation token.
    next: ?[]const u8,

    //
    // Lists one batch of files.
    //
    pub fn run(self: *ListFilesOperation, io: std.Io) !IListResult {
        return self.storage.listFiles(self.allocator, io, self.dirPath, 1000, self.next);
    }
};

//
// The retried directory listing (TypeScript: `() => storage.listDirs(dirPath, 1000, next)`).
//
const ListDirsOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => storage.listDirs(dirPath, 1000, next)";

    // The storage to list.
    storage: IStorage,

    // Allocates the result.
    allocator: std.mem.Allocator,

    // The directory to list.
    dirPath: []const u8,

    // The continuation token.
    next: ?[]const u8,

    //
    // Lists one batch of directories.
    //
    pub fn run(self: *ListDirsOperation, io: std.Io) !IListResult {
        return self.storage.listDirs(self.allocator, io, self.dirPath, 1000, self.next);
    }
};

//
// The progress through one directory of the walk (one level of the TypeScript generator recursion).
//
const WalkFrame = struct {
    // The directory being walked.
    dirPath: []const u8,

    // True once the files have been yielded and the subdirectories are being walked.
    walkingDirs: bool,

    // True when `names` holds the current batch.
    fetched: bool,

    // The names in the current batch.
    names: []const []const u8,

    // The index of the next name in the batch.
    index: usize,

    // The continuation token for the next batch.
    next: ?[]const u8,
};

//
// Walks a directory structure; call `next` for each file (TypeScript: the async generator returned by walkDirectory).
//
pub const DirectoryWalker = struct {
    // Allocates paths and listings.
    allocator: std.mem.Allocator,

    // Used for the storage calls.
    io: std.Io,

    // The storage being walked.
    storage: IStorage,

    // Paths that match any of these patterns are skipped.
    ignorePatterns: []const IgnorePattern,

    // The directories being walked, innermost last.
    stack: std.ArrayList(WalkFrame),

    //
    // Starts walking a directory.
    //
    fn pushDirectory(self: *DirectoryWalker, dirPath: []const u8) !void {
        try self.stack.append(self.allocator, .{
            .dirPath = dirPath,
            .walkingDirs = false,
            .fetched = false,
            .names = &.{},
            .index = 0,
            .next = null,
        });
    }

    //
    // Returns true if the path matches any ignore pattern.
    //
    fn shouldIgnore(self: *DirectoryWalker, fullPath: []const u8) bool {
        for (self.ignorePatterns) |pattern| {
            if (pattern(fullPath)) {
                return true;
            }
        }
        return false;
    }

    //
    // Returns the next file, or null when the walk is complete.
    //
    pub fn next(self: *DirectoryWalker) !?IOrderedFile {
        while (self.stack.items.len > 0) {
            const frame = &self.stack.items[self.stack.items.len - 1];
            if (!frame.fetched) {
                var batch: IListResult = undefined;
                if (frame.walkingDirs) {
                    var operation: ListDirsOperation = .{
                        .storage = self.storage,
                        .allocator = self.allocator,
                        .dirPath = frame.dirPath,
                        .next = frame.next,
                    };
                    batch = try retry(self.io, &operation, 3, 1_000, 2, DIRECTORY_LISTING_TIMEOUT, try std.fmt.allocPrint(self.allocator, "Failed to list the directories in {s}", .{frame.dirPath}));
                }
                else {
                    var operation: ListFilesOperation = .{
                        .storage = self.storage,
                        .allocator = self.allocator,
                        .dirPath = frame.dirPath,
                        .next = frame.next,
                    };
                    batch = try retry(self.io, &operation, 3, 1_000, 2, DIRECTORY_LISTING_TIMEOUT, try std.fmt.allocPrint(self.allocator, "Failed to list the files in {s}", .{frame.dirPath}));
                }
                frame.names = batch.names;
                frame.index = 0;
                frame.next = batch.next;
                frame.fetched = true;
            }

            if (frame.index < frame.names.len) {
                const name = frame.names[frame.index];
                frame.index += 1;
                const fullPath = try pathJoin(self.allocator, &.{ frame.dirPath, name });

                // Check if path matches any ignore patterns
                if (self.shouldIgnore(fullPath)) {
                    log.log.verbose(try std.fmt.allocPrint(self.allocator, "Ignoring {s}", .{fullPath}));
                    continue;
                }

                if (!frame.walkingDirs) {
                    return .{
                        .fileName = fullPath,
                    };
                }

                // Recursively walk subdirectories
                try self.pushDirectory(fullPath);
                continue;
            }

            if (frame.next != null) {
                // The next batch of this listing.
                frame.fetched = false;
                continue;
            }

            if (!frame.walkingDirs) {
                // The files are done: list the directories.
                frame.walkingDirs = true;
                frame.fetched = false;
                continue;
            }

            _ = self.stack.pop();
        }
        return null;
    }
};

//
// Recursively walks a directory structure and adds file paths to the provided queue
// @param dirPath Directory path to start walking from
// @param queue Queue to add file paths to
// @param ignorePatterns RegExp patterns to ignore
// (Zig: returns a walker whose `next` yields the files; pass default_ignore_patterns for the TypeScript default.)
//
pub fn walkDirectory(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, dirPath: []const u8, ignorePatterns: []const IgnorePattern) !DirectoryWalker {
    var walker: DirectoryWalker = .{
        .allocator = allocator,
        .io = io,
        .storage = storage,
        .ignorePatterns = ignorePatterns,
        .stack = .empty,
    };
    try walker.pushDirectory(dirPath);
    return walker;
}
