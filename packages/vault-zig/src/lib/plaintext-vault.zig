const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const vault_module = @import("vault.zig");
const ISecret = vault_module.ISecret;
const IVault = vault_module.IVault;
const errors = utils.errors;
const process_env = node_utils.process_env;

//
// Default directory under which the plain-text vault stores its files.
// TypeScript computes this constant when the module loads (path.join(os.homedir(), ".config", "photosphere", "vault")).
// Zig has no process-wide environment until `main` sets it (see node-utils process-env.zig), so it is computed on demand.
// Like os.homedir() the home directory is $HOME (%USERPROFILE% on Windows).
//
pub fn DEFAULT_VAULT_DIR(allocator: std.mem.Allocator) ![]const u8 {
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = process_env.getEnv(home_variable) orelse "";
    return std.fs.path.join(allocator, &.{ home_dir, ".config", "photosphere", "vault" });
}

//
// The file extension used for each secret file.
//
const SECRET_FILE_EXTENSION = ".json";

//
// Returns true for the characters that encodeURIComponent leaves unescaped:
// A-Z a-z 0-9 - _ . ! ~ * ' ( )
//
fn isUriUnreserved(character: u8) bool {
    if (std.ascii.isAlphanumeric(character)) {
        return true;
    }
    return switch (character) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

//
// Encodes a secret name into a filename-safe string using percent-encoding.
// This ensures that names containing special characters, slashes, etc.
// are stored safely on every supported filesystem.
// (TypeScript: encodeURIComponent, which percent-encodes each UTF-8 byte with upper case hex.)
//
pub fn encodeSecretName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    for (name) |character| {
        if (isUriUnreserved(character)) {
            try encoded.append(allocator, character);
        }
        else {
            try encoded.print(allocator, "%{X:0>2}", .{character});
        }
    }
    return encoded.toOwnedSlice(allocator);
}

//
// Decodes a filename back into the original secret name.
// (TypeScript: decodeURIComponent, which throws "URI malformed" for bad escapes or invalid UTF-8.)
//
pub fn decodeSecretName(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < encoded.len) {
        const character = encoded[index];
        if (character != '%') {
            try decoded.append(allocator, character);
            index += 1;
            continue;
        }
        if (index + 3 > encoded.len) {
            return errors.throwError("URI malformed", .{});
        }
        const byte = std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch {
            return errors.throwError("URI malformed", .{});
        };
        try decoded.append(allocator, byte);
        index += 3;
    }
    if (!std.unicode.utf8ValidateSlice(decoded.items)) {
        return errors.throwError("URI malformed", .{});
    }
    return decoded.toOwnedSlice(allocator);
}

//
// Returns the absolute path of the file that stores the given secret.
//
fn secretFilePath(allocator: std.mem.Allocator, vaultDir: []const u8, name: []const u8) ![]const u8 {
    const encoded_name = try encodeSecretName(allocator, name);
    const file_name = try std.mem.concat(allocator, u8, &.{ encoded_name, SECRET_FILE_EXTENSION });
    return std.fs.path.join(allocator, &.{ vaultDir, file_name });
}

//
// Unix permission mode: owner read + write only (rw-------)
//
const FILE_MODE = 0o600;

//
// Unix permission mode: owner read + write + execute only (rwx------)
// Execute is required on directories to allow listing and traversal.
//
const DIR_MODE = 0o700;

//
// Converts a Unix permission mode to Zig file permissions (the default permissions on
// platforms without POSIX modes, such as Windows).
//
fn modeToPermissions(mode: u32) std.Io.File.Permissions {
    if (comptime @hasDecl(std.Io.File.Permissions, "fromMode")) {
        return std.Io.File.Permissions.fromMode(@intCast(mode));
    }
    return .default_file;
}

//
// Ensures that a directory exists, creating it (and any missing ancestors)
// if it does not.  On platforms that support POSIX permissions the directory
// is created with mode 0o700 (owner-only access).
//
fn ensureDir(io: std.Io, dirPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, dirPath, modeToPermissions(DIR_MODE));

    // Apply the mode explicitly because the recursive flag may create
    // intermediate directories with the process umask rather than DIR_MODE.
    // chmod is not supported on all platforms (e.g. Windows); ignore errors.
    cwd.setFilePermissions(io, dirPath, modeToPermissions(DIR_MODE), .{}) catch {};
}

//
// A vault implementation that persists secrets as plain-text JSON files
// under a directory on the local filesystem.
//
// Each secret is written to its own file named after the (percent-encoded)
// secret name with a ".json" extension.  By default the vault directory is
// ~/.config/vault, but a custom directory can be supplied to the constructor
// which makes the implementation straightforward to test in isolation.
//
// This vault type is intentionally unencrypted and is intended for
// development / low-security use cases, or as a reference implementation
// for building encrypted or remote-backed vault types.
//
pub const PlaintextVault = struct {
    //
    // Absolute path to the directory where secret files are stored.
    //
    vaultDir: []const u8,

    //
    // Creates the vault (TypeScript: constructor(vaultDir = DEFAULT_VAULT_DIR); callers pass
    // DEFAULT_VAULT_DIR(allocator) for the default).
    //
    pub fn init(vaultDir: []const u8) PlaintextVault {
        return .{ .vaultDir = vaultDir };
    }

    //
    // Gets the IVault interface for this vault.
    //
    pub fn vault(self: *PlaintextVault) IVault {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IVault functions of this vault (public so callers can check which implementation an IVault has).
    //
    pub const vtable: IVault.VTable = .{
        .get = getErased,
        .set = setErased,
        .list = listErased,
    };

    //
    // Retrieves a secret by name.
    // Returns null if no secret with that name exists.
    //
    pub fn get(self: *PlaintextVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        const filePath = try secretFilePath(allocator, self.vaultDir, name);
        const raw = std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }
            return err;
        };
        return try std.json.parseFromSliceLeaky(ISecret, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    //
    // Creates or overwrites a secret.
    //
    pub fn set(self: *PlaintextVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        try ensureDir(io, self.vaultDir);
        const filePath = try secretFilePath(allocator, self.vaultDir, secret.name);

        // JSON.stringify(secret, null, 2)
        const text = try std.json.Stringify.valueAlloc(allocator, secret, .{ .whitespace = .indent_2 });
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{
            .sub_path = filePath,
            .data = text,
            .flags = .{ .permissions = modeToPermissions(FILE_MODE) },
        });

        // Apply the mode explicitly; writeFile with mode may be affected by the
        // process umask on some systems.
        // chmod is not supported on all platforms (e.g. Windows); ignore errors.
        cwd.setFilePermissions(io, filePath, modeToPermissions(FILE_MODE), .{}) catch {};
    }

    //
    // Returns all secrets stored in the vault directory.
    // Returns an empty array if the vault directory does not yet exist.
    // Entries are visited in byte order of their file names (like Node's fs.readdir, which sorts them).
    //
    pub fn list(self: *PlaintextVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        var entries: std.ArrayList([]const u8) = .empty;
        {
            var dir = std.Io.Dir.cwd().openDir(io, self.vaultDir, .{ .iterate = true }) catch |err| {
                if (err == error.FileNotFound) {
                    return &.{};
                }
                return err;
            };
            defer dir.close(io);
            var iterator = dir.iterate();
            while (try iterator.next(io)) |entry| {
                try entries.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }
        std.mem.sort([]const u8, entries.items, {}, lessThanBytes);

        var secrets: std.ArrayList(ISecret) = .empty;
        for (entries.items) |entry| {
            if (!std.mem.endsWith(u8, entry, SECRET_FILE_EXTENSION)) {
                continue;
            }
            const encodedName = entry[0 .. entry.len - SECRET_FILE_EXTENSION.len];
            const name = try decodeSecretName(allocator, encodedName);
            const secret = try self.get(allocator, io, name);
            if (secret) |found_secret| {
                try secrets.append(allocator, found_secret);
            }
        }
        return secrets.toOwnedSlice(allocator);
    }

    // Not ported: delete, exists, checkPrereqs (not used by psi replicate or psi verify).

    //
    // IVault.get for this implementation.
    //
    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        const self: *PlaintextVault = @ptrCast(@alignCast(ptr));
        return self.get(allocator, io, name);
    }

    //
    // IVault.set for this implementation.
    //
    fn setErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        const self: *PlaintextVault = @ptrCast(@alignCast(ptr));
        return self.set(allocator, io, secret);
    }

    //
    // IVault.list for this implementation.
    //
    fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        const self: *PlaintextVault = @ptrCast(@alignCast(ptr));
        return self.list(allocator, io);
    }
};

//
// Orders strings by their bytes (the order of strcmp, which libuv uses to sort fs.readdir results).
//
fn lessThanBytes(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.order(u8, left, right) == .lt;
}
