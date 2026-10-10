//
// Reads and writes whole files like Node's `readFile` and `writeFile`, with the messages of the errors they throw. A file that cannot be opened throws
// `<code>: <description>, open '<path>'` and a directory read as a file throws `EISDIR: illegal operation on a
// directory, read`, where Zig's own errors carry only their name. An error with no Node counterpart listed here is
// returned as it is.
//

const std = @import("std");
const builtin = @import("builtin");
const errors = @import("utils-zig").errors;

//
// The `<code>: <description>` Node gives the error of a file that cannot be opened, or null for an error not listed.
//
fn openErrorCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.FileNotFound => "ENOENT: no such file or directory",
        error.AccessDenied, error.PermissionDenied => "EACCES: permission denied",
        error.IsDir => "EISDIR: illegal operation on a directory",
        error.NotDir => "ENOTDIR: not a directory",
        error.NameTooLong => "ENAMETOOLONG: name too long",
        error.NoSpaceLeft => "ENOSPC: no space left on device",
        error.ReadOnlyFileSystem => "EROFS: read-only file system",
        else => null,
    };
}

//
// Reads a whole file (`fs.readFile(filePath, 'utf8')`).
//
pub fn readFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited) catch |err| {
        if (err == error.IsDir) {
            return errors.throwError("EISDIR: illegal operation on a directory, read", .{});
        }
        const code = openErrorCode(err) orelse {
            return err;
        };
        return errors.throwError("{s}, open '{s}'", .{ code, filePath });
    };
}

//
// Writes a whole file, replacing what it held (`fs.writeFile(filePath, data)`).
//
pub fn writeFile(io: std.Io, filePath: []const u8, data: []const u8) !void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = filePath,
        .data = data,
    }) catch |err| {
        const code = openErrorCode(err) orelse {
            return err;
        };
        return errors.throwError("{s}, open '{s}'", .{ code, filePath });
    };
}

//
// Lists the names of the entries in a directory (`fs.readdir(directoryPath)` from "fs/promises"), in the order the
// operating system gives them. A directory that cannot be read throws `<code>: <description>, scandir '<path>'`.
//
pub fn readdir(allocator: std.mem.Allocator, io: std.Io, directoryPath: []const u8) ![]const []const u8 {
    var directory = std.Io.Dir.cwd().openDir(io, directoryPath, .{ .iterate = true }) catch |err| {
        const code = openErrorCode(err) orelse {
            return err;
        };
        return errors.throwError("{s}, scandir '{s}'", .{ code, directoryPath });
    };
    defer directory.close(io);

    var entryNames: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try entryNames.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return entryNames.items;
}

//
// What `fs.statfs` reports about a filesystem that is read here: `bavail` and `bsize`.
//
pub const IStatFs = struct {
    // Free blocks available to an unprivileged user.
    bavail: u64,

    // Size of a block in bytes.
    bsize: u64,
};

//
// The struct statfs of 64-bit Linux and Android, which is what the statfs system call fills in (the same layout on x86_64 and aarch64).
//
const LinuxStatfs = extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]c_int,
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
};

//
// The struct statfs of macOS and iOS, with 64-bit inode numbers.
//
const DarwinStatfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_reserved: [8]u32,
};

//
// Fills in a DarwinStatfs for a path (libc). A 64-bit Intel Mac exports the layout with 64-bit inode numbers under this symbol name.
//
extern "c" fn @"statfs$INODE64"(path: [*:0]const u8, buffer: *DarwinStatfs) c_int;

//
// Fills in a DarwinStatfs for a path (libc).
//
extern "c" fn statfs(path: [*:0]const u8, buffer: *DarwinStatfs) c_int;

//
// Gets the free space of a Windows volume (kernel32).
//
extern "kernel32" fn GetDiskFreeSpaceExW(
    directoryName: [*:0]const u16,
    freeBytesAvailableToCaller: *u64,
    totalNumberOfBytes: *u64,
    totalNumberOfFreeBytes: *u64,
) callconv(.winapi) std.os.windows.BOOL;

//
// Reads the free space of the filesystem that holds a path. A path that does not
// exist returns error.FileNotFound, as Node's ENOENT does; any other failure throws `E<NAME>, statfs '<path>'`.
// Zig's standard library has no statfs, so this calls the operating system: the statfs system call on Linux and Android,
// libc's statfs on macOS and iOS, and GetDiskFreeSpaceExW on Windows, which reports the free bytes as bavail blocks of one byte.
//
pub fn statfsPath(allocator: std.mem.Allocator, filePath: []const u8) !IStatFs {
    const pathZ = try allocator.dupeZ(u8, filePath);
    switch (builtin.os.tag) {
        .linux => {
            comptime std.debug.assert(@sizeOf(usize) == 8);
            var buffer: LinuxStatfs = undefined;
            const result = std.os.linux.syscall2(.statfs, @intFromPtr(pathZ.ptr), @intFromPtr(&buffer));
            const code = std.os.linux.errno(result);
            if (code == .SUCCESS) {
                return .{
                    .bavail = buffer.f_bavail,
                    .bsize = @intCast(buffer.f_bsize),
                };
            }
            if (code == .NOENT) {
                return error.FileNotFound;
            }
            return errors.throwError("E{s}, statfs '{s}'", .{ @tagName(code), filePath });
        },
        .macos, .ios => {
            var buffer: DarwinStatfs = undefined;
            const result = if (builtin.cpu.arch == .x86_64) @"statfs$INODE64"(pathZ.ptr, &buffer) else statfs(pathZ.ptr, &buffer);
            if (result == 0) {
                return .{
                    .bavail = buffer.f_bavail,
                    .bsize = buffer.f_bsize,
                };
            }
            const code = std.posix.errno(result);
            if (code == .NOENT) {
                return error.FileNotFound;
            }
            return errors.throwError("E{s}, statfs '{s}'", .{ @tagName(code), filePath });
        },
        .windows => {
            const pathW = try std.unicode.utf8ToUtf16LeAllocZ(allocator, filePath);
            var freeBytesAvailable: u64 = 0;
            var totalBytes: u64 = 0;
            var totalFreeBytes: u64 = 0;
            if (GetDiskFreeSpaceExW(pathW.ptr, &freeBytesAvailable, &totalBytes, &totalFreeBytes) == .FALSE) {
                const code = std.os.windows.GetLastError();
                if (code == .FILE_NOT_FOUND or code == .PATH_NOT_FOUND) {
                    return error.FileNotFound;
                }
                return errors.throwError("{s}, statfs '{s}'", .{ @tagName(code), filePath });
            }
            return .{
                .bavail = freeBytesAvailable,
                .bsize = 1,
            };
        },
        else => @compileError("statfsPath has no implementation for this operating system"),
    }
}
