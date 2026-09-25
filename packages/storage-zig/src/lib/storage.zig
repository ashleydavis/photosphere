const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const errors = utils.errors;
const Date = utils.timestamp_provider.Date;

//
// Partial result of the list operation.
//
pub const IListResult = struct {
    //
    // The list of file or directories names found in storage.
    //
    names: []const []const u8,

    //
    // If there are more assets to read the contination token is set.
    //
    next: ?[]const u8,
};

//
// Information about a file.
//
pub const IFileInfo = struct {
    //
    // The content type of the file.
    // This is returned from cloud storage, but not from file storage.
    //
    contentType: ?[]const u8,

    //
    // The length of the file in bytes.
    //
    length: u64,

    //
    // The last modified date of the file (milliseconds since the Unix epoch, like a JS Date).
    //
    lastModified: i64,
};

//
// Information about a write lock.
//
pub const IWriteLockInfo = struct {
    //
    // The owner of the lock.
    //
    owner: []const u8,

    //
    // The time when the lock was acquired.
    //
    acquiredAt: Date,

    //
    // The unix timestamp when the lock was acquired.
    //
    timestamp: i64,
};

//
// The contents of a lock file, as `JSON.stringify(lockInfo)` writes them and `JSON.parse` reads them back.
// (No TypeScript counterpart: TypeScript builds and reads an anonymous object.)
//
pub const LockFileContent = struct {
    // The owner of the lock.
    owner: []const u8,

    // The ISO date-time when the lock was acquired.
    acquiredAt: []const u8,

    // The unix timestamp when the lock was acquired.
    timestamp: i64,
};

//
// Reads the lock information from the contents of a lock file (TypeScript: `JSON.parse(lockContent.trim())`
// followed by `{ owner, acquiredAt: new Date(lockData.acquiredAt), timestamp }`).
// (Zig: content that is not the JSON the lock methods write, including an acquiredAt that `new Date` could not
// parse, fails with the error JSON.parse would raise.)
//
pub fn parseLockContent(allocator: std.mem.Allocator, lockContent: []const u8) !IWriteLockInfo {
    const trimmed = std.mem.trim(u8, lockContent, " \t\r\n");
    const lockData = std.json.parseFromSliceLeaky(LockFileContent, allocator, trimmed, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| {
        return errors.throwError("JSON Parse error: {s}", .{@errorName(err)});
    };
    const acquiredAt = parseISOString(lockData.acquiredAt) orelse {
        return errors.throwError("Invalid Date: {s}", .{lockData.acquiredAt});
    };
    return .{
        .owner = lockData.owner,
        .acquiredAt = acquiredAt,
        .timestamp = lockData.timestamp,
    };
}

//
// Parses the YYYY-MM-DDTHH:mm:ss.sssZ form `toISOString` writes (TypeScript: `new Date(isoString)`), or returns
// null for any other text. (No TypeScript counterpart: stands in for the Date parser of the JavaScript runtime.)
//
pub fn parseISOString(text: []const u8) ?Date {
    if (text.len != 24 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or text[13] != ':' or text[16] != ':' or text[19] != '.' or text[23] != 'Z') {
        return null;
    }
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch {
        return null;
    };
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch {
        return null;
    };
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch {
        return null;
    };
    const hours = std.fmt.parseInt(i64, text[11..13], 10) catch {
        return null;
    };
    const minutes = std.fmt.parseInt(i64, text[14..16], 10) catch {
        return null;
    };
    const seconds = std.fmt.parseInt(i64, text[17..19], 10) catch {
        return null;
    };
    const milliseconds = std.fmt.parseInt(i64, text[20..23], 10) catch {
        return null;
    };
    if (month < 1 or month > 12 or day < 1 or day > 31 or hours > 24 or minutes > 59 or seconds > 59) {
        return null;
    }

    // Days since 1970-01-01 (Howard Hinnant's days_from_civil algorithm).
    const shiftedYear = if (month <= 2) year - 1 else year;
    const era = @divFloor(shiftedYear, 400);
    const yearOfEra = shiftedYear - era * 400;
    const shiftedMonth = if (month > 2) month - 3 else month + 9;
    const dayOfYear = @divFloor(153 * shiftedMonth + 2, 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100) + dayOfYear;
    const days = era * 146097 + dayOfEra - 719468;
    return .{
        .epochMilliseconds = ((days * 24 + hours) * 60 + minutes) * 60 * 1000 + seconds * 1000 + milliseconds,
    };
}

//
// Gets the id of this process (TypeScript: `process.pid`). (No TypeScript counterpart: stands in for the runtime.)
//
pub fn processId() i64 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    };
}

//
// A readable stream returned by IStorage.readStream (the equivalent of a Node Readable).
// Callers read from `reader()` and must call `destroy()` when finished (like Readable.destroy()).
//
pub const IReadStream = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IReadStream provides.
    //
    pub const VTable = struct {
        // Gets the reader that yields the stream's bytes.
        reader: *const fn (ptr: *anyopaque) *std.Io.Reader,

        // Releases the stream's resources.
        destroy: *const fn (ptr: *anyopaque, io: std.Io) void,
    };

    //
    // Gets the reader that yields the stream's bytes.
    //
    pub fn reader(self: IReadStream) *std.Io.Reader {
        return self.vtable.reader(self.ptr);
    }

    //
    // Releases the stream's resources.
    //
    pub fn destroy(self: IReadStream, io: std.Io) void {
        self.vtable.destroy(self.ptr, io);
    }
};

//
// Abstract storage (file system, S3, encrypted, prefixed).
// Every method takes the caller's allocator (returned memory belongs to it) and io.
//
pub const IStorage = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // Gets the location of the storage.
    //
    location: []const u8,

    //
    // The functions an implementation of IStorage provides (same names as the TypeScript interface).
    //
    pub const VTable = struct {
        // Returns true if the specified directory is empty.
        isEmpty: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!bool,

        // List files in storage.
        listFiles: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult,

        // List directories in storage.
        listDirs: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult,

        // Returns true if the specified file exists.
        fileExists: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!bool,

        // Returns true if the specified directory exists (contains at least one file or subdirectory).
        dirExists: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!bool,

        // Gets info about a file.
        info: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IFileInfo,

        // Reads a file from storage. Returns null if the file doesn't exist.
        read: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?[]u8,

        // Writes a file to storage.
        write: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) anyerror!void,

        // Streams a file from storage.
        readStream: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!IReadStream,

        // Writes an input stream to storage.
        writeStream: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void,

        // Deletes a file from storage.
        deleteFile: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void,

        // Deletes a directory and all its contents from storage.
        deleteDir: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!void,

        // Copies a file from one location to another.
        copyTo: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) anyerror!void,

        // Checks if a write lock is acquired for the specified file.
        // Returns the lock information if it exists, undefined otherwise.
        checkWriteLock: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IWriteLockInfo,

        // Attempts to acquire a write lock for the specified file.
        // Returns true if the lock was acquired, false if it already exists.
        acquireWriteLock: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool,

        // Releases a write lock for the specified file.
        releaseWriteLock: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void,

        // Not ported: readableLength, writeStreamHashed, storedHash, refreshWriteLock
        // (not reached by psi replicate or psi verify).
    };

    //
    // Returns true if the specified directory is empty.
    //
    pub fn isEmpty(self: IStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!bool {
        return self.vtable.isEmpty(self.ptr, allocator, io, path);
    }

    //
    // List files in storage.
    //
    pub fn listFiles(self: IStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        return self.vtable.listFiles(self.ptr, allocator, io, path, max, next);
    }

    //
    // List directories in storage.
    //
    pub fn listDirs(self: IStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        return self.vtable.listDirs(self.ptr, allocator, io, path, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    pub fn fileExists(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!bool {
        return self.vtable.fileExists(self.ptr, allocator, io, filePath);
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    pub fn dirExists(self: IStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!bool {
        return self.vtable.dirExists(self.ptr, allocator, io, dirPath);
    }

    //
    // Gets info about a file.
    //
    pub fn info(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IFileInfo {
        return self.vtable.info(self.ptr, allocator, io, filePath);
    }

    //
    // Reads a file from storage.
    // Returns null if the file doesn't exist.
    //
    pub fn read(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?[]u8 {
        return self.vtable.read(self.ptr, allocator, io, filePath);
    }

    //
    // Writes a file to storage.
    //
    pub fn write(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) anyerror!void {
        return self.vtable.write(self.ptr, allocator, io, filePath, contentType, data);
    }

    //
    // Streams a file from storage.
    //
    pub fn readStream(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!IReadStream {
        return self.vtable.readStream(self.ptr, allocator, io, filePath);
    }

    //
    // Writes an input stream to storage.
    //
    pub fn writeStream(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        return self.vtable.writeStream(self.ptr, allocator, io, filePath, contentType, inputStream, contentLength);
    }

    //
    // Deletes a file from storage.
    //
    pub fn deleteFile(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        return self.vtable.deleteFile(self.ptr, allocator, io, filePath);
    }

    //
    // Deletes a directory and all its contents from storage.
    //
    pub fn deleteDir(self: IStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!void {
        return self.vtable.deleteDir(self.ptr, allocator, io, dirPath);
    }

    //
    // Copies a file from one location to another.
    //
    pub fn copyTo(self: IStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) anyerror!void {
        return self.vtable.copyTo(self.ptr, allocator, io, srcPath, destPath);
    }

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    pub fn checkWriteLock(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IWriteLockInfo {
        return self.vtable.checkWriteLock(self.ptr, allocator, io, filePath);
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    pub fn acquireWriteLock(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool {
        return self.vtable.acquireWriteLock(self.ptr, allocator, io, filePath, owner);
    }

    //
    // Releases a write lock for the specified file.
    //
    pub fn releaseWriteLock(self: IStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        return self.vtable.releaseWriteLock(self.ptr, allocator, io, filePath);
    }
};

//
// Builds the IStorage vtable for a storage implementation whose methods have the same names and parameters as
// IStorage (with `self: *Implementation` in place of the type erased pointer). (No TypeScript counterpart: a TS class
// implements the interface directly.)
//
pub fn implement(comptime Implementation: type) *const IStorage.VTable {
    //
    // Forwards each IStorage function to the method of the implementation.
    //
    const Adapter = struct {
        //
        // Converts the type erased pointer back to the implementation.
        //
        fn cast(ptr: *anyopaque) *Implementation {
            return @ptrCast(@alignCast(ptr));
        }

        //
        // Forwards isEmpty.
        //
        fn isEmpty(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!bool {
            return cast(ptr).isEmpty(allocator, io, path);
        }

        //
        // Forwards listFiles.
        //
        fn listFiles(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
            return cast(ptr).listFiles(allocator, io, path, max, next);
        }

        //
        // Forwards listDirs.
        //
        fn listDirs(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
            return cast(ptr).listDirs(allocator, io, path, max, next);
        }

        //
        // Forwards fileExists.
        //
        fn fileExists(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!bool {
            return cast(ptr).fileExists(allocator, io, filePath);
        }

        //
        // Forwards dirExists.
        //
        fn dirExists(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!bool {
            return cast(ptr).dirExists(allocator, io, dirPath);
        }

        //
        // Forwards info.
        //
        fn info(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IFileInfo {
            return cast(ptr).info(allocator, io, filePath);
        }

        //
        // Forwards read.
        //
        fn read(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?[]u8 {
            return cast(ptr).read(allocator, io, filePath);
        }

        //
        // Forwards write.
        //
        fn write(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) anyerror!void {
            return cast(ptr).write(allocator, io, filePath, contentType, data);
        }

        //
        // Forwards readStream.
        //
        fn readStream(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!IReadStream {
            return cast(ptr).readStream(allocator, io, filePath);
        }

        //
        // Forwards writeStream.
        //
        fn writeStream(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
            return cast(ptr).writeStream(allocator, io, filePath, contentType, inputStream, contentLength);
        }

        //
        // Forwards deleteFile.
        //
        fn deleteFile(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
            return cast(ptr).deleteFile(allocator, io, filePath);
        }

        //
        // Forwards deleteDir.
        //
        fn deleteDir(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!void {
            return cast(ptr).deleteDir(allocator, io, dirPath);
        }

        //
        // Forwards copyTo.
        //
        fn copyTo(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) anyerror!void {
            return cast(ptr).copyTo(allocator, io, srcPath, destPath);
        }

        //
        // Forwards checkWriteLock.
        //
        fn checkWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IWriteLockInfo {
            return cast(ptr).checkWriteLock(allocator, io, filePath);
        }

        //
        // Forwards acquireWriteLock.
        //
        fn acquireWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool {
            return cast(ptr).acquireWriteLock(allocator, io, filePath, owner);
        }

        //
        // Forwards releaseWriteLock.
        //
        fn releaseWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
            return cast(ptr).releaseWriteLock(allocator, io, filePath);
        }

        //
        // The vtable that forwards to the implementation.
        //
        const vtable: IStorage.VTable = .{
            .isEmpty = isEmpty,
            .listFiles = listFiles,
            .listDirs = listDirs,
            .fileExists = fileExists,
            .dirExists = dirExists,
            .info = info,
            .read = read,
            .write = write,
            .readStream = readStream,
            .writeStream = writeStream,
            .deleteFile = deleteFile,
            .deleteDir = deleteDir,
            .copyTo = copyTo,
            .checkWriteLock = checkWriteLock,
            .acquireWriteLock = acquireWriteLock,
            .releaseWriteLock = releaseWriteLock,
        };
    };
    return &Adapter.vtable;
}

//
// Builds the IReadStream vtable for a stream type with `reader(self) *std.Io.Reader` and `destroy(self, io) void`
// methods. (No TypeScript counterpart.)
//
pub fn implementReadStream(comptime Implementation: type) *const IReadStream.VTable {
    //
    // Forwards each IReadStream function to the method of the implementation.
    //
    const Adapter = struct {
        //
        // Forwards reader.
        //
        fn reader(ptr: *anyopaque) *std.Io.Reader {
            const self: *Implementation = @ptrCast(@alignCast(ptr));
            return self.reader();
        }

        //
        // Forwards destroy.
        //
        fn destroy(ptr: *anyopaque, io: std.Io) void {
            const self: *Implementation = @ptrCast(@alignCast(ptr));
            self.destroy(io);
        }

        //
        // The vtable that forwards to the implementation.
        //
        const vtable: IReadStream.VTable = .{
            .reader = reader,
            .destroy = destroy,
        };
    };
    return &Adapter.vtable;
}
