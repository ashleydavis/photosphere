const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const pc = @import("picocolors.zig");
const prompts = @import("clack/prompts.zig");
const select = prompts.select;
const text = prompts.text;
const isCancel = prompts.isCancel;
const outro = prompts.outro;
const exit = node_utils.termination.exit;
const pathExists = node_utils.fs.pathExists;
const log = &utils.log.log;

//
// Joins path segments (`path.join`).
//
fn join(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    return node_utils.path.join(allocator, &.{ left, right });
}

//
// Resolves a path against the current working directory (`path.resolve`).
//
fn resolve(allocator: std.mem.Allocator, io: std.Io, pathToResolve: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    return std.fs.path.resolve(allocator, &.{ cwd, pathToResolve });
}

//
// Creates a directory and its parents (`fs.mkdir(path, { recursive: true })`). A failure throws the error Node
// throws, whose message is `<code>: <description>, mkdir '<path>'`.
//
fn mkdirRecursive(io: std.Io, dirPath: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, dirPath) catch |err| {
        const code: []const u8 = switch (err) {
            // Zig reports a path that exists as a file as NotDir, where Node reports EEXIST for the path itself.
            error.NotDir => if (isExistingFile(io, dirPath)) "EEXIST: file already exists" else "ENOTDIR: not a directory",
            error.PathAlreadyExists => "EEXIST: file already exists",
            error.FileNotFound => "ENOENT: no such file or directory",
            error.AccessDenied, error.PermissionDenied => "EACCES: permission denied",
            error.NameTooLong => "ENAMETOOLONG: name too long",
            error.NoSpaceLeft => "ENOSPC: no space left on device",
            error.ReadOnlyFileSystem => "EROFS: read-only file system",
            else => return err,
        };
        return utils.errors.throwError("{s}, mkdir '{s}'", .{ code, dirPath });
    };
}

//
// True when the path is there and is not a directory.
//
fn isExistingFile(io: std.Io, filePath: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, filePath, .{}) catch {
        return false;
    };
    return stat.kind != .directory;
}

//
// Checks if a directory is a valid Photosphere media database
//
pub fn isMediaDatabase(allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
    const dbDir = try join(allocator, dirPath, ".db");
    if (!pathExists(io, dbDir)) {
        return false;
    }

    const filesDatPath = try join(allocator, dbDir, "files.dat");
    const treeDatPath = try join(allocator, dbDir, "tree.dat");
    return pathExists(io, filesDatPath) or pathExists(io, treeDatPath);
}

//
// Checks if a directory is empty or doesn't exist (suitable for init)
//
fn isEmptyOrNonExistent(io: std.Io, dirPath: []const u8) bool {
    if (!pathExists(io, dirPath)) {
        return true;
    }

    var dir = std.Io.Dir.cwd().openDir(io, dirPath, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var iterator = dir.iterate();
    const first = iterator.next(io) catch return false;
    return first == null;
}

//
// The result of a directory validator: null when the directory is valid (TypeScript `true`), otherwise
// the message that explains why it is not (TypeScript returns a string, or false for "Invalid directory").
//
pub const ValidatorResult = ?[]const u8;

//
// A directory validator (TypeScript: `(path: string) => Promise<boolean | string>`).
//
pub const Validator = *const fn (allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!ValidatorResult;

//
// The state of the subdirectory name validator.
//
const SubdirectoryValidateContext = struct {
    // Io used to check whether the directory exists.
    io: std.Io,

    // The directory the subdirectory is created in.
    currentPath: []const u8,
};

//
// Validates the name of a new subdirectory.
//
fn validateSubdirectoryName(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    const self: *SubdirectoryValidateContext = @ptrCast(@alignCast(context.?));
    const name = value orelse return "Directory name is required";
    if (utils.js_string.trim(name).len == 0) {
        return "Directory name is required";
    }
    // Check for invalid characters
    if (std.mem.indexOfAny(u8, name, "/\\:*?\"<>|") != null) {
        return "Directory name contains invalid characters";
    }
    // Check if directory already exists
    var pathBuffer: [std.fs.max_path_bytes]u8 = undefined;
    var pathAllocator = std.heap.FixedBufferAllocator.init(&pathBuffer);
    const newPath = join(pathAllocator.allocator(), self.currentPath, name) catch |err| switch (err) {
        // Longer than any path the system accepts, so it cannot exist (Node's existsSync returns false for it).
        error.OutOfMemory => return null,
    };
    if (pathExists(self.io, newPath)) {
        return "Directory already exists";
    }
    return null;
}

//
// Validates a full directory path.
//
fn validateFullPath(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const pathText = value orelse return "Path is required";
    if (utils.js_string.trim(pathText).len == 0) {
        return "Path is required";
    }
    return null;
}

//
// Prompts user to select a directory with simplified options
//
pub fn pickDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    message: []const u8,
    currentDir: []const u8,
    validator: ?Validator,
) !?[]const u8 {
    const currentPath = try resolve(allocator, io, currentDir);

    // Check if current directory is valid
    var canUseCurrentDir = true;
    if (validator) |validate| {
        const result = try validate(allocator, io, currentPath);
        if (result != null) {
            canUseCurrentDir = false;
        }
    }

    var options: std.ArrayList(prompts.Option) = .empty;

    // Option 1: Use current directory (only if empty/valid)
    if (canUseCurrentDir) {
        try options.append(allocator, .{
            .label = "\u{1F4C1} Use current directory",
            .value = "current",
        });
    }

    // Option 2: Create subdirectory
    try options.append(allocator, .{
        .label = "\u{1F4C2} Create subdirectory in current location",
        .value = "subdirectory",
    });

    // Option 3: Enter full path
    try options.append(allocator, .{
        .label = "\u{1F4DD} Enter full path",
        .value = "fullpath",
    });

    // Cancel option
    try options.append(allocator, .{
        .label = "\u{274C} Cancel",
        .value = "cancel",
    });

    // Note about current directory will be shown in the prompt message if needed

    const choice = try select(allocator, io, .{
        .message = message,
        .options = options.items,
    });

    if (isCancel(choice)) {
        return null;
    }

    const choiceValue = choice.value;
    if (std.mem.eql(u8, choiceValue, "current")) {
        return ".";
    }
    else if (std.mem.eql(u8, choiceValue, "subdirectory")) {
        const validateContext = try allocator.create(SubdirectoryValidateContext);
        validateContext.* = .{ .io = io, .currentPath = currentPath };
        const subdirName = try text(allocator, io, .{
            .message = "Enter name for subdirectory:",
            .placeholder = "my-photos",
            .validate = .{ .context = validateContext, .function = validateSubdirectoryName },
        });

        if (isCancel(subdirName)) {
            return null;
        }

        const trimmedName = utils.js_string.trim(subdirName.value);
        const subdirPath = try join(allocator, currentPath, trimmedName);
        const relativePath = try std.fmt.allocPrint(allocator, "./{s}", .{trimmedName});
        mkdirRecursive(io, subdirPath) catch |err| {
            try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "Failed to create directory: {s}", .{utils.errors.errorMessage(err)})), .{});
            return null;
        };

        // Validate the new directory
        if (validator) |validate| {
            const result = try validate(allocator, io, subdirPath);
            if (result) |problem| {
                try outro(io, try pc.red(allocator, problem), .{});
                return null;
            }
        }

        return relativePath;
    }
    else if (std.mem.eql(u8, choiceValue, "fullpath")) {
        const fullPath = try text(allocator, io, .{
            .message = "Enter full directory path:",
            .placeholder = "/path/to/directory",
            .validate = .{ .context = null, .function = validateFullPath },
        });

        if (isCancel(fullPath)) {
            return null;
        }

        const resolvedPath = try resolve(allocator, io, utils.js_string.trim(fullPath.value));

        // Create directory if it doesn't exist
        if (!pathExists(io, resolvedPath)) {
            mkdirRecursive(io, resolvedPath) catch |err| {
                try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "Failed to create directory: {s}", .{utils.errors.errorMessage(err)})), .{});
                return null;
            };
        }

        // Validate the directory
        if (validator) |validate| {
            const result = try validate(allocator, io, resolvedPath);
            if (result) |problem| {
                try outro(io, try pc.red(allocator, problem), .{});
                return null;
            }
        }

        return resolvedPath;
    }
    else if (std.mem.eql(u8, choiceValue, "cancel")) {
        return null;
    }
    else {
        return null;
    }
}

//
// Validates directory for init command (empty or non-existent)
//
fn validateInitDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!ValidatorResult {
    _ = allocator;
    if (isEmptyOrNonExistent(io, path)) {
        return null;
    }

    return "can't use this directory because it's not empty";
}

//
// Validates directory for other commands (existing media database)
//
pub fn validateExistingDatabase(allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!ValidatorResult {
    if (!pathExists(io, path)) {
        return "Directory does not exist";
    }

    if (try isMediaDatabase(allocator, io, path)) {
        return null;
    }

    return "Directory is not a valid Photosphere media database";
}

//
// The kind of directory a command needs (TypeScript: 'init' | 'existing').
//
pub const CommandType = enum {
    // An empty or non-existent directory for a new database.
    init,

    // An existing media database.
    existing,
};

//
// Auto-detects and prompts for directory based on command type
//
pub fn getDirectoryForCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    commandType: CommandType,
    nonInteractive: bool,
    cwd: []const u8,
) ![]const u8 {
    // Check if current directory is suitable
    const currentDir = cwd;

    if (commandType == .init) {
        if (try validateInitDirectory(allocator, io, currentDir) == null) {
            return currentDir;
        }
        else {
            // Current directory is not empty, skip asking and go straight to picker in interactive mode
            if (nonInteractive) {
                log.@"error"(try pc.red(allocator, "Current directory is not empty. Please specify an empty directory or use a different location."));
                exit(io, 1);
            }
        }
    }
    else {
        if (try isMediaDatabase(allocator, io, currentDir)) {
            return currentDir;
        }
    }

    // If non-interactive and we get here, we can't proceed
    if (nonInteractive) {
        if (commandType == .init) {
            log.@"error"(try pc.red(allocator, "Current directory is not empty. Please specify an empty directory or use a different location."));
        }
        else {
            log.@"error"(try pc.red(allocator, "Current directory is not a media database. Please specify a valid media database directory."));
        }
        exit(io, 1);
    }

    // Interactive mode: show directory picker
    const message = if (commandType == .init)
        "Select an empty directory for new media database:"
    else
        "Select an existing media database directory:";

    const validator: Validator = if (commandType == .init)
        validateInitDirectory
    else
        validateExistingDatabase;

    const selectedDir = try pickDirectory(allocator, io, message, currentDir, validator);

    if (selectedDir == null) {
        try outro(io, try pc.red(allocator, "No directory selected"), .{});
        exit(io, 1);
    }

    return selectedDir.?;
}
