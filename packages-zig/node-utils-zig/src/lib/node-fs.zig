//
// Port of the parts of Node's `fs` module that the TypeScript calls directly: `readFile` and `writeFile` (from "fs",
// "fs/promises" or "fs-extra"), with the messages of the errors they throw. A file that cannot be opened throws
// `<code>: <description>, open '<path>'` and a directory read as a file throws `EISDIR: illegal operation on a
// directory, read`, where Zig's own errors carry only their name. An error with no Node counterpart listed here is
// returned as it is.
//

const std = @import("std");
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
