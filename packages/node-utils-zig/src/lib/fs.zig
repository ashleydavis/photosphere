const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const errors = utils.errors;
const toml = @import("toml.zig");
const process_env = @import("process-env.zig");

//
// Ensures that the directory exists. If the directory structure does not exist, it is created.
// Like fs-extra's ensureDir, but using native fs.promises.
//
pub fn ensureDir(io: std.Io, dirPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dirPath) catch |err| {
        // With recursive: true, mkdir should not throw EEXIST if directory exists
        // But if it does, or if path exists as a file, handle it
        // (Zig reports a path that exists as a file as NotDir where Node reports EEXIST.)
        if (err == error.PathAlreadyExists or err == error.NotDir) {
            // Verify it's actually a directory
            const stats = try cwd.statFile(io, dirPath, .{});
            if (stats.kind != .directory) {
                return errors.throwError("Path exists but is not a directory: {s}", .{dirPath});
            }
        }
        else {
            return err;
        }
    };
}

//
// Ensures that the directory containing the file exists. If the directory structure does not exist, it is created.
//
pub fn ensureFileDir(io: std.Io, filePath: []const u8) !void {
    const dirPath = std.fs.path.dirname(filePath) orelse ".";
    return ensureDir(io, dirPath);
}

//
// Checks if a path exists (file or directory).
//
pub fn pathExists(io: std.Io, filePath: []const u8) bool {
    std.Io.Dir.cwd().access(io, filePath, .{}) catch {
        return false;
    };
    return true;
}

//
// Removes a file or directory. Works like fs-extra's remove.
//
pub fn remove(io: std.Io, targetPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stats = cwd.statFile(io, targetPath, .{}) catch |err| {
        // If file/directory doesn't exist, that's fine (like fs-extra behavior)
        if (err == error.FileNotFound) {
            return;
        }
        return err;
    };

    if (stats.kind == .directory) {
        try cwd.deleteTree(io, targetPath);
    }
    else {
        cwd.deleteFile(io, targetPath) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        };
    }
}

//
// Outputs a file ensuring the directory exists. Like fs-extra's outputFile.
// The TypeScript `options` (encoding and mode) are not ported: data is written as given with default permissions.
//
pub fn outputFile(io: std.Io, filePath: []const u8, data: []const u8) !void {
    try ensureFileDir(io, filePath);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filePath, .data = data });
}

//
// Reads a JSON file and parses it. Like fs-extra's readJson.
// The TypeScript `options` (encoding and flag) are not ported: the file is read as UTF-8.
//
pub fn readJson(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !std.json.Value {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{});
}

//
// Reads a TOML file and parses it.
//
pub fn readToml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !toml.TomlValue {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    return toml.parse(allocator, data);
}

//
// Writes an object to a TOML file, creating parent directories as needed.
//
pub fn writeToml(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, object: toml.TomlValue) !void {
    const tomlString = try toml.stringify(allocator, object);
    try outputFile(io, filePath, tomlString);
}

// Not ported: writeJson, emptyDir, copy (not used by replicate or verify).

//
// Synchronous version: Ensures that the directory exists.
//
pub fn ensureDirSync(io: std.Io, dirPath: []const u8) !void {
    return ensureDir(io, dirPath);
}

// Not ported: removeSync, copySync (not used by replicate or verify).

//
// Equivalent of Node's `os.tmpdir()`.
// On POSIX: TMPDIR, TMP or TEMP (without a trailing slash), else /tmp.
// On Windows: TEMP, TMP, else %SystemRoot%\temp (or %windir%\temp), without a trailing backslash unless the
// path is a drive root.
//
pub fn osTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        var windowsPath: []const u8 = "";
        const windowsNames = [_][]const u8{ "TEMP", "TMP" };
        for (windowsNames) |name| {
            if (windowsPath.len == 0) {
                windowsPath = process_env.getEnv(name) orelse "";
            }
        }
        if (windowsPath.len == 0) {
            var systemRoot: []const u8 = process_env.getEnv("SystemRoot") orelse "";
            if (systemRoot.len == 0) {
                systemRoot = process_env.getEnv("windir") orelse "undefined";
            }
            windowsPath = try std.mem.concat(allocator, u8, &.{ systemRoot, "\\temp" });
        }
        if (windowsPath.len > 1 and std.mem.endsWith(u8, windowsPath, "\\") and !std.mem.endsWith(u8, windowsPath, ":\\")) {
            return windowsPath[0 .. windowsPath.len - 1];
        }
        return windowsPath;
    }
    const names = [_][]const u8{ "TMPDIR", "TMP", "TEMP" };
    for (names) |name| {
        if (process_env.getEnv(name)) |value| {
            if (value.len == 0) {
                continue;
            }
            if (value.len > 1 and value[value.len - 1] == '/') {
                return value[0 .. value.len - 1];
            }
            return value;
        }
    }
    return "/tmp";
}

//
// Returns the temp directory to use for this process.
// When TEST_TMP_DIR env var is set (test isolation mode), uses a subdirectory of the
// test's isolated dir so temp files are scoped per-test and cleaned up between runs.
// Otherwise returns the system temp dir.
//
pub fn getProcessTmpDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (process_env.getEnv("TEST_TMP_DIR")) |testTmpDir| {
        if (testTmpDir.len > 0) {
            const currentPath = try std.process.currentPathAlloc(io, allocator);
            return std.fs.path.resolve(allocator, &.{ currentPath, testTmpDir, "tmp" });
        }
    }
    return osTmpDir(allocator);
}
