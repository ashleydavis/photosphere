const std = @import("std");
const storage_zig = @import("storage-zig");
const storage = storage_zig.storage;
const IStorage = storage.IStorage;
const IReadStream = storage.IReadStream;
const IFileInfo = storage.IFileInfo;
const IListResult = storage.IListResult;
const IWriteLockInfo = storage.IWriteLockInfo;

//
// In-memory IStorage for tests: a port of the TypeScript MockStorage (storage/src/tests/mock-storage.ts), which the
// bdb TypeScript tests and the fixture generator use. Directories are remembered when a file is written below them and
// stay until deleteDir, exactly like MockStorage, so dirExists and listDirs behave the same in both languages.
//
pub const MemoryStorage = struct {
    // Allocates stored file contents, paths and streams.
    allocator: std.mem.Allocator,

    // Stored files by path.
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    // Known directories.
    directories: std.StringArrayHashMapUnmanaged(void) = .empty,

    // Held write locks by lock file path.
    locks: std.StringArrayHashMapUnmanaged(IWriteLockInfo) = .empty,

    //
    // Creates an empty storage.
    //
    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator };
    }

    //
    // Gets the IStorage interface of this storage.
    //
    pub fn asStorage(self: *MemoryStorage) IStorage {
        return .{ .ptr = self, .vtable = storage.implement(MemoryStorage), .location = "memory://mock" };
    }

    //
    // Stores a file and registers its parent directories (MockStorage.write).
    //
    pub fn putFile(self: *MemoryStorage, filePath: []const u8, data: []const u8) !void {
        const ownedPath = try self.allocator.dupe(u8, filePath);
        const ownedData = try self.allocator.dupe(u8, data);
        try self.files.put(self.allocator, ownedPath, ownedData);

        const lastSlash = std.mem.lastIndexOfScalar(u8, ownedPath, '/') orelse {
            return;
        };
        var currentDir = ownedPath[0..lastSlash];
        if (currentDir.len > 0) {
            try self.directories.put(self.allocator, currentDir, {});
        }
        while (std.mem.indexOfScalar(u8, currentDir, '/') != null) {
            currentDir = currentDir[0..std.mem.lastIndexOfScalar(u8, currentDir, '/').?];
            if (currentDir.len > 0) {
                try self.directories.put(self.allocator, currentDir, {});
            }
        }
    }

    //
    // Gets the stored data of a file (test assertions).
    //
    pub fn getFile(self: *MemoryStorage, filePath: []const u8) ?[]const u8 {
        return self.files.get(filePath);
    }

    //
    // Copies every file below a directory on disk into the storage under a prefix.
    //
    pub fn loadDirectory(self: *MemoryStorage, io: std.Io, directoryPath: []const u8, prefix: []const u8) !void {
        var directory = try std.Io.Dir.cwd().openDir(io, directoryPath, .{ .iterate = true });
        defer directory.close(io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const data = try directory.readFileAlloc(io, entry.path, self.allocator, .unlimited);
            const storagePath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, entry.path });

            // Storage paths use '/', but the walker joins the path with '\' on Windows.
            std.mem.replaceScalar(u8, storagePath, '\\', '/');
            try self.putFile(storagePath, data);
        }
    }

    //
    // Writes every stored file to a directory on disk (so the TypeScript CLI code can read what Zig wrote).
    //
    pub fn writeToDirectory(self: *MemoryStorage, io: std.Io, directoryPath: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        for (self.files.keys(), self.files.values()) |filePath, data| {
            const diskPath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directoryPath, filePath });
            if (std.fs.path.dirname(diskPath)) |parent| {
                try cwd.createDirPath(io, parent);
            }
            try cwd.writeFile(io, .{ .sub_path = diskPath, .data = data });
        }
    }

    //
    // Sort predicate for paths (JavaScript's default sort order; the paths are ASCII).
    //
    fn pathLessThan(context: void, left: []const u8, right: []const u8) bool {
        _ = context;
        return std.mem.lessThan(u8, left, right);
    }

    //
    // Returns a path relative to a prefix without a leading slash.
    //
    fn relativeName(prefix: []const u8, fullPath: []const u8) []const u8 {
        const relativePath = fullPath[prefix.len..];
        if (relativePath.len > 0 and relativePath[0] == '/') {
            return relativePath[1..];
        }
        return relativePath;
    }

    //
    // Returns one page of names from a sorted list (the paging logic shared by listFiles and listDirs).
    //
    fn page(self: *MemoryStorage, allocator: std.mem.Allocator, prefix: []const u8, sorted: []const []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = self;
        var startIndex: usize = 0;
        if (next) |marker| {
            for (sorted, 0..) |candidate, candidateIndex| {
                if (std.mem.eql(u8, candidate, marker)) {
                    startIndex = candidateIndex + 1;
                    break;
                }
            }
        }
        const endIndex = @min(startIndex + max, sorted.len);
        var names: std.ArrayList([]const u8) = .empty;
        for (sorted[startIndex..endIndex]) |candidate| {
            try names.append(allocator, relativeName(prefix, candidate));
        }
        return .{ .names = names.items, .next = if (endIndex < sorted.len) sorted[endIndex] else null };
    }

    //
    // Returns true when there is no file or subdirectory below the path.
    //
    pub fn isEmpty(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        _ = io;
        const pathPrefix = try std.fmt.allocPrint(allocator, "{s}/", .{path});
        for (self.directories.keys()) |directory| {
            if (!std.mem.eql(u8, directory, path) and std.mem.startsWith(u8, directory, pathPrefix)) {
                return false;
            }
        }
        for (self.files.keys()) |filePath| {
            if (std.mem.startsWith(u8, filePath, pathPrefix)) {
                return false;
            }
        }
        return true;
    }

    //
    // Lists the files whose path starts with the prefix.
    //
    pub fn listFiles(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = io;
        var keys: std.ArrayList([]const u8) = .empty;
        for (self.files.keys()) |filePath| {
            if (std.mem.startsWith(u8, filePath, path)) {
                try keys.append(allocator, filePath);
            }
        }
        std.mem.sort([]const u8, keys.items, {}, pathLessThan);
        return self.page(allocator, path, keys.items, max, next);
    }

    //
    // Lists the directories directly below the prefix.
    //
    pub fn listDirs(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = io;
        var directories: std.ArrayList([]const u8) = .empty;
        for (self.directories.keys()) |directory| {
            if (!std.mem.startsWith(u8, directory, path)) {
                continue;
            }
            const relativePath = directory[path.len..];
            if (relativePath.len == 0) {
                continue;
            }
            if (relativePath.len > 1 and std.mem.indexOfScalar(u8, relativePath[1..], '/') != null) {
                continue;
            }
            try directories.append(allocator, directory);
        }
        std.mem.sort([]const u8, directories.items, {}, pathLessThan);
        return self.page(allocator, path, directories.items, max, next);
    }

    //
    // Returns true when the file exists.
    //
    pub fn fileExists(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        _ = allocator;
        _ = io;
        return self.files.contains(filePath);
    }

    //
    // Returns true when the directory is known.
    //
    pub fn dirExists(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        _ = allocator;
        _ = io;
        return self.directories.contains(dirPath);
    }

    //
    // Gets the length of a file (null when it does not exist).
    //
    pub fn info(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        _ = allocator;
        const data = self.files.get(filePath) orelse {
            return null;
        };
        return .{ .contentType = null, .length = data.len, .lastModified = std.Io.Clock.real.now(io).toMilliseconds() };
    }

    //
    // Reads a whole file (null when it does not exist).
    //
    pub fn read(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        _ = io;
        const data = self.files.get(filePath) orelse {
            return null;
        };
        return try allocator.dupe(u8, data);
    }

    //
    // Writes a whole file.
    //
    pub fn write(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = contentType;
        try self.putFile(filePath, data);
    }

    //
    // Opens a stream that reads a file.
    //
    pub fn readStream(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        _ = io;
        const data = self.files.get(filePath) orelse {
            return error.FileNotFound;
        };
        const stream = try allocator.create(MemoryStream);
        stream.* = .{ .interface = .fixed(data) };
        return .{ .ptr = stream, .vtable = storage.implementReadStream(MemoryStream) };
    }

    //
    // Writes a stream to a file.
    //
    pub fn writeStream(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        _ = contentLength;
        const data = try inputStream.allocRemaining(allocator, .unlimited);
        try self.write(allocator, io, filePath, contentType, data);
    }

    //
    // Deletes a file (no error when it does not exist).
    //
    pub fn deleteFile(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = self.files.orderedRemove(filePath);
    }

    //
    // Deletes a directory and everything below it.
    //
    pub fn deleteDir(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        _ = io;
        _ = self.directories.orderedRemove(dirPath);
        const pathPrefix = try std.fmt.allocPrint(allocator, "{s}/", .{dirPath});
        var fileIndex: usize = 0;
        while (fileIndex < self.files.count()) {
            if (std.mem.startsWith(u8, self.files.keys()[fileIndex], pathPrefix)) {
                self.files.orderedRemoveAt(fileIndex);
            }
            else {
                fileIndex += 1;
            }
        }
        var directoryIndex: usize = 0;
        while (directoryIndex < self.directories.count()) {
            if (std.mem.startsWith(u8, self.directories.keys()[directoryIndex], pathPrefix)) {
                self.directories.orderedRemoveAt(directoryIndex);
            }
            else {
                directoryIndex += 1;
            }
        }
    }

    //
    // Copies a file.
    //
    pub fn copyTo(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        const data = self.files.get(srcPath) orelse {
            return error.FileNotFound;
        };
        try self.write(allocator, io, destPath, null, data);
    }

    //
    // Gets the write lock held for a lock file, if any.
    //
    pub fn checkWriteLock(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {
        _ = allocator;
        _ = io;
        return self.locks.get(filePath);
    }

    //
    // Acquires the write lock for a lock file (false when it is already held).
    //
    pub fn acquireWriteLock(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {
        _ = allocator;
        if (self.locks.contains(filePath)) {
            return false;
        }

        const timestamp = std.Io.Clock.real.now(io).toMilliseconds();
        try self.locks.put(self.allocator, try self.allocator.dupe(u8, filePath), .{
            .owner = try self.allocator.dupe(u8, owner),
            .acquiredAt = .{ .epochMilliseconds = timestamp },
            .timestamp = timestamp,
        });
        return true;
    }

    //
    // Releases the write lock for a lock file.
    //
    pub fn releaseWriteLock(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = self.locks.orderedRemove(filePath);
    }
};

//
// A stream over a stored file.
//
pub const MemoryStream = struct {
    // Reads the file data.
    interface: std.Io.Reader,

    //
    // Gets the reader of the stream.
    //
    pub fn reader(self: *MemoryStream) *std.Io.Reader {
        return &self.interface;
    }

    //
    // Closes the stream (nothing to release).
    //
    pub fn destroy(self: *MemoryStream, io: std.Io) void {
        _ = self;
        _ = io;
    }
};
