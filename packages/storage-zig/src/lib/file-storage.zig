const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_module = @import("storage.zig");
const locale_compare = @import("locale-compare.zig");

const errors = utils.errors;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const ensureDir = node_utils.fs.ensureDir;
const pathExists = node_utils.fs.pathExists;

// Not ported: WRITE_LOCK_TIMEOUT_MS (write locks are not used by psi replicate or psi verify).

//
// The size of the buffer used when reading or writing a file stream.
//
const stream_buffer_length = 64 * 1024;

//
// Storage on the local file system. Paths passed to the methods are full file system paths
// (createStorage wraps this in a StoragePrefixWrapper that adds the database directory).
//
pub const FileStorage = struct {
    //
    // Gets the location of the storage.
    //
    location: []const u8,

    //
    // Creates file storage (TypeScript: `new FileStorage(location)`).
    //
    pub fn init(location: []const u8) FileStorage {
        return .{ .location = location };
    }

    //
    // Gets the IStorage interface of this storage (TypeScript: the class implements IStorage).
    //
    pub fn storage(self: *FileStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(FileStorage), .location = self.location };
    }

    //
    // Returns true if the specified directory is empty.
    //
    pub fn isEmpty(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        _ = self;
        _ = allocator;
        if (!pathExists(io, path)) {
            return true;
        }
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        const firstEntry = try iterator.next(io);
        return firstEntry == null;
    }

    //
    // List files in storage.
    //
    pub fn listFiles(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = self;
        _ = max;
        _ = next;
        if (!pathExists(io, path)) {
            return .{
                .names = &.{},
                .next = null,
            };
        }

        const names = try readDirNames(allocator, io, path, false);

        //
        // Alphanumeric sort to simulate the order of file listing from S3.
        // This allows the files to be listed in the same order as they would be listed in S3.
        // This is important for building the hash tree as the order of files affects the hash tree.
        //
        std.mem.sort([]const u8, names, {}, locale_compare.lessThan);

        return .{
            .names = names,
            .next = null,
        };
    }

    //
    // List files in storage.
    //
    pub fn listDirs(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = self;
        _ = max;
        _ = next;
        if (!pathExists(io, path)) {
            return .{
                .names = &.{},
                .next = null,
            };
        }

        const names = try readDirNames(allocator, io, path, true);

        //
        // Alphanumeric sort to simulate the order of file listing from S3.
        // This allows the files to be listed in the same order as they would be listed in S3.
        // This is important for building the hash tree as the order of files affects the hash tree.
        //
        std.mem.sort([]const u8, names, {}, locale_compare.lessThan);

        return .{
            .names = names,
            .next = null,
        };
    }

    //
    // Returns true if the specified file exists.
    //
    pub fn fileExists(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        _ = self;
        _ = allocator;
        if (!pathExists(io, filePath)) {
            return false;
        }

        // Ensure it's a file, not a directory
        const stats = try std.Io.Dir.cwd().statFile(io, filePath, .{});
        return stats.kind == .file;
    }

    //
    // Returns true if the specified directory exists.
    //
    pub fn dirExists(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        _ = self;
        _ = allocator;
        if (!pathExists(io, dirPath)) {
            return false;
        }

        // Ensure it's a directory
        const stats = try std.Io.Dir.cwd().statFile(io, dirPath, .{});
        return stats.kind == .directory;
    }

    //
    // Gets info about a file.
    //
    pub fn info(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        _ = self;
        _ = allocator;
        if (!pathExists(io, filePath)) {
            return null;
        }
        const stat = try std.Io.Dir.cwd().statFile(io, filePath, .{});
        if (stat.kind != .file) {
            // If it's not a file, return undefined.
            return null;
        }
        return .{
            .contentType = null, // This is not available in file storage.
            .length = stat.size,
            .lastModified = stat.mtime.toMilliseconds(),
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    pub fn read(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        _ = self;
        if (!pathExists(io, filePath)) {
            // Returns undefined if the file doesn't exist.
            return null;
        }

        return try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    }

    //
    // Writes a file to storage.
    //
    pub fn write(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = self;
        _ = contentType;

        try ensureDir(io, dirname(filePath));
        const tmpPath = try std.fmt.allocPrint(allocator, "{s}.tmp", .{filePath});
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmpPath, .data = data });
        try cwd.rename(tmpPath, cwd, filePath, io);
    }

    //
    // Streams a file from stroage.
    // (Zig: the file is opened here, so a missing file fails now with Node's ENOENT message instead of on the first read.)
    //
    pub fn readStream(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        _ = self;
        return createReadStream(allocator, io, filePath);
    }

    //
    // Writes an input stream to storage.
    //
    pub fn writeStream(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, _contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        _ = self;
        _ = _contentType;
        _ = contentLength;
        const tmpPath = try std.fmt.allocPrint(allocator, "{s}.tmp", .{filePath});
        try ensureDir(io, dirname(filePath));
        try pipeline(allocator, io, inputStream, tmpPath);
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(tmpPath, cwd, filePath, io);
    }

    //
    // Deletes a file from storage.
    //
    pub fn deleteFile(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = self;
        _ = allocator;
        std.Io.Dir.cwd().deleteFile(io, filePath) catch {
            // Ignore errors if the file doesn't exist
        };
    }

    //
    // Deletes a directory and all its contents from storage.
    //
    pub fn deleteDir(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        _ = self;
        _ = allocator;
        std.Io.Dir.cwd().deleteTree(io, dirPath) catch {
            // Ignore errors if the directory doesn't exist
        };
    }

    //
    // Copies a file from one location to another.
    // Src file path is a full path, dest path is relative to the storage root.
    // (Zig: node-utils `copy` (fs-extra) is not ported; this copies a single file, directories are not supported.)
    //
    pub fn copyTo(self: *FileStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        _ = self;
        _ = allocator;
        try ensureDir(io, dirname(destPath));
        const cwd = std.Io.Dir.cwd();
        try cwd.copyFile(srcPath, cwd, destPath, io, .{});
    }

    // Not ported: checkWriteLock, acquireWriteLock, releaseWriteLock, refreshWriteLock
    // (write locks are not used by psi replicate or psi verify).
};

//
// Reads the names of the entries of a directory that are (or are not) directories
// (TypeScript: `fs.readdir(path, { withFileTypes: true })` followed by a filter on `entry.isDirectory()`).
//
fn readDirNames(allocator: std.mem.Allocator, io: std.Io, path: []const u8, directories: bool) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const isDirectory = entry.kind == .directory;
        if (isDirectory != directories) {
            continue;
        }
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}

//
// Gets the directory part of a path like Node's `path.dirname` ("." for a bare file name).
//
fn dirname(filePath: []const u8) []const u8 {
    return std.fs.path.dirname(filePath) orelse ".";
}

//
// Copies everything from a reader into a new file (TypeScript: `pipeline(inputStream, createWriteStream(tmpPath))`).
//
fn pipeline(allocator: std.mem.Allocator, io: std.Io, inputStream: *std.Io.Reader, outputPath: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, outputPath, .{});
    defer file.close(io);
    const buffer = try allocator.alloc(u8, stream_buffer_length);
    defer allocator.free(buffer);
    var fileWriter = file.writer(io, buffer);
    _ = try inputStream.streamRemaining(&fileWriter.interface);
    try fileWriter.interface.flush();
}

//
// A readable stream over a file (TypeScript: `fs.createReadStream(filePath)`).
//
pub const FileReadStream = struct {
    // The allocator that allocated this stream.
    allocator: std.mem.Allocator,

    // The open file.
    file: std.Io.File,

    // The reader over the file.
    fileReader: std.Io.File.Reader,

    // The read buffer.
    buffer: []u8,

    //
    // Gets the reader that yields the file's bytes.
    //
    pub fn reader(self: *FileReadStream) *std.Io.Reader {
        return &self.fileReader.interface;
    }

    //
    // Closes the file and frees the stream.
    //
    pub fn destroy(self: *FileReadStream, io: std.Io) void {
        self.file.close(io);
        const allocator = self.allocator;
        allocator.free(self.buffer);
        allocator.destroy(self);
    }

    //
    // Gets the IReadStream interface of this stream.
    //
    pub fn readStream(self: *FileReadStream) IReadStream {
        return .{ .ptr = self, .vtable = storage_module.implementReadStream(FileReadStream) };
    }
};

//
// Opens a file for streaming (TypeScript: `createReadStream(filePath)`), failing with Node's message when it is missing.
//
fn createReadStream(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
    const file = std.Io.Dir.cwd().openFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return errors.throwError("ENOENT: no such file or directory, open '{s}'", .{filePath});
        }
        return err;
    };
    errdefer file.close(io);
    const self = try allocator.create(FileReadStream);
    errdefer allocator.destroy(self);
    const buffer = try allocator.alloc(u8, stream_buffer_length);
    self.* = .{
        .allocator = allocator,
        .file = file,
        .fileReader = file.reader(io, buffer),
        .buffer = buffer,
    };
    return self.readStream();
}
