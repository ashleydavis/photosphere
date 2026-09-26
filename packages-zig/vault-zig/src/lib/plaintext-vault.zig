const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const vault_module = @import("vault.zig");
const ISecret = vault_module.ISecret;
const IVault = vault_module.IVault;
const errors = utils.errors;
const process_env = node_utils.process_env;
const updateFileOptimistic = node_utils.fs.updateFileOptimistic;

//
// Default directory under which the plain-text vault stores its vault file.
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
// The name of the single file that holds every secret in the vault.
//
pub const VAULT_FILE_NAME = "vault.json";

//
// Unix permission mode: owner read + write only (rw-------)
//
pub const FILE_MODE = 0o600;

//
// Unix permission mode: owner read + write + execute only (rwx------)
// Execute is required on directories to allow listing and traversal.
//
pub const DIR_MODE = 0o700;

//
// How many times an update reloads and re-applies its change when another writer
// published to the vault file first, before giving up and throwing.
//
pub const UPDATE_RETRIES = 3;

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
pub fn ensureDir(io: std.Io, dirPath: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, dirPath, modeToPermissions(DIR_MODE));

    // Apply the mode explicitly because the recursive flag may create
    // intermediate directories with the process umask rather than DIR_MODE.
    // chmod is not supported on all platforms (e.g. Windows); ignore errors.
    // (Zig: on Windows Node's chmod only toggles the read-only attribute, which an owner-writable mode
    // leaves off, and Zig's setFilePermissions panics there, so it is skipped.)
    if (builtin.os.tag != .windows) {
        cwd.setFilePermissions(io, dirPath, modeToPermissions(DIR_MODE), .{}) catch {};
    }
}

//
// The path of the single file that holds every secret in a vault directory.
//
pub fn getVaultFilePath(allocator: std.mem.Allocator, vaultDir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ vaultDir, VAULT_FILE_NAME });
}

//
// Restricts a file to owner read + write.
//
pub fn applyFileMode(io: std.Io, filePath: []const u8) void {
    // chmod is not supported on all platforms (e.g. Windows); ignore errors.
    // (Zig: skipped on Windows, see ensureDir.)
    if (builtin.os.tag != .windows) {
        std.Io.Dir.cwd().setFilePermissions(io, filePath, modeToPermissions(FILE_MODE), .{}) catch {};
    }
}

//
// The on-disk shape of the vault file: a JSON object whose keys are secret
// names and whose values are the secrets stored under those names.  A secret
// name lives in a JSON key, so a colon, slash or unicode character in a name
// needs no encoding of any kind.
// (Zig: the parsed JSON object, keys in the order a JavaScript object keeps them; see orderLikeJavaScript.)
//
pub const IVaultFile = std.json.ObjectMap;

//
// Returns true when a property name is an array index ("0" to "4294967294" written without leading
// zeros), which a JavaScript object orders before every other property name.
//
fn isArrayIndex(name: []const u8) bool {
    if (name.len == 0 or name.len > 10) {
        return false;
    }
    if (name.len > 1 and name[0] == '0') {
        return false;
    }
    for (name) |character| {
        if (!std.ascii.isDigit(character)) {
            return false;
        }
    }
    const index = std.fmt.parseInt(u64, name, 10) catch {
        return false;
    };
    return index < 4294967295;
}

//
// Orders the keys of an object the way a JavaScript object does (and therefore the way JSON.stringify
// and Object.values visit them): array index names first in ascending numeric order, then every other
// name in insertion order. (No TypeScript counterpart: this is JavaScript object semantics.)
//
fn orderLikeJavaScript(contents: *IVaultFile) void {
    //
    // Sorts array index names first, by value; the sort is stable so other names keep their order.
    //
    const SortContext = struct {
        // The keys of the object being sorted.
        keys: [][]const u8,

        //
        // Returns true when the key at leftIndex belongs before the key at rightIndex.
        //
        pub fn lessThan(self: @This(), leftIndex: usize, rightIndex: usize) bool {
            const left = self.keys[leftIndex];
            const right = self.keys[rightIndex];
            const leftIsIndex = isArrayIndex(left);
            const rightIsIndex = isArrayIndex(right);
            if (leftIsIndex and rightIsIndex) {
                return std.fmt.parseInt(u64, left, 10) catch unreachable < std.fmt.parseInt(u64, right, 10) catch unreachable;
            }
            return leftIsIndex and !rightIsIndex;
        }
    };
    contents.sort(SortContext{ .keys = contents.keys() });
}

//
// Equivalent of `JSON.parse(raw) as IVaultFile` for the vault file.
//
fn parseVaultFile(allocator: std.mem.Allocator, raw: []const u8) !IVaultFile {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, raw, .{
        .duplicate_field_behavior = .use_last,
    });
    if (parsed != .object) {
        // (Zig: a vault file holding JSON that is not an object cannot be represented; TypeScript would
        // carry on with whatever value it is.)
        return errors.throwError("The vault file does not hold a JSON object", .{});
    }
    var contents = parsed.object;
    orderLikeJavaScript(&contents);
    return contents;
}

//
// Reads every secret out of a vault directory's vault file.
// Returns an empty set when the file does not exist yet.  A file that exists but does not parse
// throws, because silently treating a corrupt vault as an empty one would hide the damage and
// then overwrite it.
//
pub fn readVaultFile(allocator: std.mem.Allocator, io: std.Io, vaultDir: []const u8) !IVaultFile {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, try getVaultFilePath(allocator, vaultDir), allocator, .unlimited) catch |err| {
        if (err == error.FileNotFound) {
            return .empty;
        }
        return err;
    };
    return parseVaultFile(allocator, raw);
}

//
// The parse passed to updateFileOptimistic (`raw => JSON.parse(raw) as IVaultFile`).
//
const VaultFileParse = struct {
    // Unused. Present so the parser is a value with methods.
    unused: u8 = 0,

    //
    // Parses the vault file's text.
    //
    pub fn run(self: VaultFileParse, allocator: std.mem.Allocator, raw: []const u8) !IVaultFile {
        _ = self;
        return parseVaultFile(allocator, raw);
    }
};

//
// The serialize passed to updateFileOptimistic (`contents => JSON.stringify(contents, null, 2)`).
//
const VaultFileSerialize = struct {
    // Unused. Present so the serializer is a value with methods.
    unused: u8 = 0,

    //
    // Serializes the vault file's contents.
    //
    pub fn run(self: VaultFileSerialize, allocator: std.mem.Allocator, contents: IVaultFile) ![]const u8 {
        _ = self;
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = contents }, .{ .whitespace = .indent_2 });
    }
};

//
// The mutator passed to updateFileOptimistic (`contents => { mutator(contents); return contents; }`).
// It changes a copy of the contents, so that the fallback is not changed between attempts.
//
fn VaultFileMutator(comptime MutatorT: type) type {
    return struct {
        // The caller's change, a value with a method `run(self, allocator, contents: *IVaultFile) !void`.
        mutator: MutatorT,

        //
        // Applies the caller's change and returns the changed contents.
        //
        pub fn run(self: *const @This(), allocator: std.mem.Allocator, current: IVaultFile) !IVaultFile {
            var contents = try current.clone(allocator);
            try self.mutator.run(allocator, &contents);
            orderLikeJavaScript(&contents);
            return contents;
        }
    };
}

//
// Applies a change to a vault directory's vault file. Every write goes through here.
//
// The mutator is handed the file's CURRENT contents and changes them in place. updateFileOptimistic
// takes an exclusive lock beside the file, re-checks the file has not moved before renaming the new
// contents into place, and re-runs the mutator against the fresh contents if it has. It also makes
// publishing atomic, so an interrupted write leaves the previous vault rather than a truncated one.
//
// The whole vault lives in one file, so the read-all/write-all pair this replaces lost secrets: two
// processes each adding a secret both read the same contents, and whichever wrote second dropped
// the other's secret. Two CLI invocations storing credentials at once is enough to hit that.
//
// In Zig the mutator (TypeScript: `(contents: IVaultFile) => void`) is a value with a method
// `run(self, allocator, contents: *IVaultFile) !void`.
//
pub fn updateVaultFile(allocator: std.mem.Allocator, io: std.Io, vaultDir: []const u8, mutator: anytype) !void {
    // The update takes its lock beside the file, so the directory has to exist first, and has to be
    // created here to get owner-only permissions rather than the default ones the update would use.
    try ensureDir(io, vaultDir);

    const filePath = try getVaultFilePath(allocator, vaultDir);
    const vault_file_mutator: VaultFileMutator(@TypeOf(mutator)) = .{
        .mutator = mutator,
    };
    try updateFileOptimistic(IVaultFile, allocator, io, filePath, .empty, &vault_file_mutator, VaultFileParse{}, VaultFileSerialize{}, UPDATE_RETRIES);

    // The update publishes by renaming a temp file into place, and that temp file is created with
    // the default permissions, so the mode has to be reapplied to the file it becomes. Nothing is
    // exposed in between: the owner-only directory above is what stops another user reading it.
    applyFileMode(io, filePath);
}

//
// Converts a secret held in the vault file to an ISecret.
//
fn toSecret(allocator: std.mem.Allocator, value: std.json.Value) !ISecret {
    return std.json.parseFromValueLeaky(ISecret, allocator, value, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

//
// Converts an ISecret to the JSON object stored in the vault file (keys in the order name, type, value,
// the order of the object literals the callers pass).
//
fn fromSecret(allocator: std.mem.Allocator, secret: ISecret) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{ .string = secret.name });
    try object.put(allocator, "type", .{ .string = secret.type });
    try object.put(allocator, "value", .{ .string = secret.value });
    return .{ .object = object };
}

//
// The change PlaintextVault.set makes to the vault file (`contents[secret.name] = secret`).
//
const SetSecretMutator = struct {
    // The secret to store.
    secret: ISecret,

    //
    // Stores the secret under its name.
    //
    pub fn run(self: SetSecretMutator, allocator: std.mem.Allocator, contents: *IVaultFile) !void {
        try contents.put(allocator, self.secret.name, try fromSecret(allocator, self.secret));
    }
};

//
// A vault implementation that persists secrets as a single plain-text JSON
// file under a directory on the local filesystem.
//
// Every secret is held in one "vault.json" file, keyed by secret name.  By
// default the vault directory is ~/.config/vault, but a custom directory can
// be supplied to the constructor which makes the implementation
// straightforward to test in isolation.
//
// This vault type is intentionally unencrypted and is intended for
// development / low-security use cases, or as a reference implementation
// for building encrypted or remote-backed vault types.
//
pub const PlaintextVault = struct {
    //
    // Absolute path to the directory that holds the vault file.
    //
    vaultDir: []const u8,

    // Not ported: vaultFilePath (only used by exists, which is not ported).

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
        const contents = try readVaultFile(allocator, io, self.vaultDir);
        const secret = contents.get(name) orelse {
            return null;
        };
        return try toSecret(allocator, secret);
    }

    //
    // Creates or overwrites a secret.
    //
    pub fn set(self: *PlaintextVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        try updateVaultFile(allocator, io, self.vaultDir, SetSecretMutator{ .secret = secret });
    }

    //
    // Returns all secrets stored in the vault file.
    // Returns an empty array if the vault file does not yet exist.
    //
    pub fn list(self: *PlaintextVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        const contents = try readVaultFile(allocator, io, self.vaultDir);
        var secrets: std.ArrayList(ISecret) = .empty;
        for (contents.values()) |secret| {
            try secrets.append(allocator, try toSecret(allocator, secret));
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
