const std = @import("std");
const utils = @import("utils-zig");
const vault_module = @import("vault.zig");
const keychain_types = @import("keychain-types.zig");
const ISecret = vault_module.ISecret;
const IVault = vault_module.IVault;
const IPrereqCheckResult = vault_module.IPrereqCheckResult;
const toKeychainName = keychain_types.toKeychainName;
const fromKeychainName = keychain_types.fromKeychainName;
const runCommand = keychain_types.runCommand;
const errors = utils.errors;

//
// The secret-tool CLI name on Linux.
//
const SECRET_TOOL = "secret-tool";

//
// The keychain service name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Set to true once the tool availability check has been performed.
//
var toolChecked = std.atomic.Value(bool).init(false);

//
// Checks that secret-tool is installed and available on PATH.
// Returns ok=true on success, or ok=false with an error message on failure.
//
fn checkPrereqsOnce(allocator: std.mem.Allocator, io: std.Io) IPrereqCheckResult {
    if (runCommand(allocator, io, &.{ "which", SECRET_TOOL })) |_| {
        return .{ .ok = true, .message = null };
    }
    else |_| {
        return .{
            .ok = false,
            .message = "secret-tool is not installed. Install it with: sudo apt install libsecret-tools",
        };
    }
}

//
// Checks that secret-tool is available, logging its version.
// Throws a clear error if the tool is not found, suggesting how to install it.
//
fn checkTool(allocator: std.mem.Allocator, io: std.Io) !void {
    if (toolChecked.swap(true, .acq_rel)) {
        return;
    }
    const result = checkPrereqsOnce(allocator, io);
    if (!result.ok) {
        return errors.throwError("{s}", .{result.message.?});
    }
    _ = try runCommand(allocator, io, &.{ "which", SECRET_TOOL });
}

//
// Forgets that the tool availability check has been performed (tests only; TypeScript tests get a
// fresh module per test file instead).
//
pub fn resetToolChecked() void {
    toolChecked.store(false, .release);
}

//
// A parsed entry from `secret-tool search` stderr output.
//
pub const ISearchEntry = struct {
    //
    // The keychain account name (includes psi- prefix).
    //
    account: []const u8,

    //
    // The photosphere secret type stored as the secrettype attribute.
    //
    secretType: []const u8,
};

//
// The state of parseSearchOutput between attribute lines (the variables captured by flushEntry in TypeScript).
//
const SearchParseState = struct {
    // The entries found so far.
    entries: std.ArrayList(ISearchEntry),

    // The account of the entry being parsed.
    currentAccount: ?[]const u8,

    // The secret type of the entry being parsed.
    currentSecretType: ?[]const u8,

    //
    // Adds the entry being parsed (when it is a photosphere entry) and starts a new one.
    //
    fn flushEntry(self: *SearchParseState, allocator: std.mem.Allocator) !void {
        if (self.currentAccount) |account| {
            if (std.mem.startsWith(u8, account, "psi-")) {
                try self.entries.append(allocator, .{ .account = account, .secretType = self.currentSecretType orelse "plain" });
            }
        }
        self.currentAccount = null;
        self.currentSecretType = null;
    }
};

//
// Parses `secret-tool search` stderr output into account/secrettype pairs.
// Each entry block contains attribute lines; blank lines separate entries.
//
pub fn parseSearchOutput(allocator: std.mem.Allocator, output: []const u8) ![]ISearchEntry {
    var state: SearchParseState = .{ .entries = .empty, .currentAccount = null, .currentSecretType = null };

    const account_prefix = "attribute.account = ";
    const secret_type_prefix = "attribute.secrettype = ";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, keychain_types.whitespace);
        if (std.mem.startsWith(u8, trimmed, account_prefix)) {
            try state.flushEntry(allocator);
            state.currentAccount = std.mem.trim(u8, trimmed[account_prefix.len..], keychain_types.whitespace);
        }
        else if (std.mem.startsWith(u8, trimmed, secret_type_prefix)) {
            state.currentSecretType = std.mem.trim(u8, trimmed[secret_type_prefix.len..], keychain_types.whitespace);
        }
        else if (trimmed.len == 0) {
            try state.flushEntry(allocator);
        }
    }
    try state.flushEntry(allocator);

    return state.entries.toOwnedSlice(allocator);
}

//
// Runs `secret-tool search` filtered to our service and returns the stderr output.
// secret-tool search writes attribute lines to stderr, so capturing stderr
// is required to parse which secrets exist and their types.
//
fn runSecretToolSearchAll(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try keychain_types.spawn(allocator, io, &.{
        SECRET_TOOL, "search", "--all",
        "service",   KEYCHAIN_SERVICE,
    }, null);
    if (result.code) |code| {
        if (code == 0 or code == 1) {
            return result.stderr;
        }
    }
    const code_text = if (result.code) |code| try std.fmt.allocPrint(allocator, "{d}", .{code}) else "null";
    return errors.throwError("secret-tool search exited with code {s}", .{code_text});
}

//
// Runs `secret-tool search` for a single account and returns the stderr output.
// Used by get() to retrieve the secrettype attribute for a specific entry.
//
fn runSecretToolSearchOne(allocator: std.mem.Allocator, io: std.Io, keychainName: []const u8) ![]const u8 {
    const result = try keychain_types.spawn(allocator, io, &.{
        SECRET_TOOL, "search",         "--all",
        "service",   KEYCHAIN_SERVICE, "account",
        keychainName,
    }, null);
    if (result.code) |code| {
        if (code == 0 or code == 1) {
            return result.stderr;
        }
    }
    const code_text = if (result.code) |code| try std.fmt.allocPrint(allocator, "{d}", .{code}) else "null";
    return errors.throwError("secret-tool search exited with code {s}", .{code_text});
}

//
// Runs `secret-tool store` with the secret value piped to stdin.
// The secret type is stored as a `secrettype` attribute so the raw value
// is visible in keychain GUI tools instead of a JSON wrapper.
//
fn runSecretToolStore(allocator: std.mem.Allocator, io: std.Io, keychainName: []const u8, secretType: []const u8, value: []const u8) !void {
    const label_arg = try std.fmt.allocPrint(allocator, "--label={s}", .{keychainName});
    const result = try keychain_types.spawn(allocator, io, &.{
        SECRET_TOOL,  "store",
        label_arg,    "service",
        KEYCHAIN_SERVICE, "account",
        keychainName, "secrettype",
        secretType,
    }, value);
    if (result.code) |code| {
        if (code == 0) {
            return;
        }
    }
    const stderr = std.mem.trim(u8, result.stderr, keychain_types.whitespace);
    const code_text = if (result.code) |code| try std.fmt.allocPrint(allocator, "{d}", .{code}) else "null";
    return errors.throwError("secret-tool store exited with code {s}. stderr: {s}", .{ code_text, stderr });
}

//
// A vault implementation that persists secrets via the secret-tool CLI,
// which talks to any Secret Service API daemon (GNOME Keyring, KWallet, etc.).
//
// Every secret name stored is prefixed with "psi-" to make photosphere entries
// clearly identifiable.  Native listing via `secret-tool search` means no
// index file is needed on Linux.
//
// The secret type is stored as a `secrettype` attribute so the raw secret value
// is visible in keychain GUI tools instead of being wrapped in JSON.
//
pub const LinuxKeychainVault = struct {
    // Unused. Present because an IVault must point at a value with an address.
    unused: u8,

    //
    // Creates the vault.
    //
    pub fn init() LinuxKeychainVault {
        return .{ .unused = 0 };
    }

    //
    // Gets the IVault interface for this vault.
    //
    pub fn vault(self: *LinuxKeychainVault) IVault {
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
    // Retrieves a secret by name from the Secret Service.
    // Returns null if no secret with that name exists.
    //
    pub fn get(self: *LinuxKeychainVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        _ = self;
        try checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, name);
        const value = runCommand(allocator, io, &.{ SECRET_TOOL, "lookup", "service", KEYCHAIN_SERVICE, "account", keychainName }) catch {
            return null;
        };
        if (value.len == 0) {
            return null;
        }
        const searchOutput = try runSecretToolSearchOne(allocator, io, keychainName);
        const entries = try parseSearchOutput(allocator, searchOutput);
        var secretType: []const u8 = "plain";
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.account, keychainName)) {
                secretType = entry.secretType;
                break;
            }
        }
        return .{ .name = name, .type = secretType, .value = value };
    }

    //
    // Creates or overwrites a secret in the Secret Service.
    // The type is stored as a keychain attribute; the value is stored as-is.
    //
    pub fn set(self: *LinuxKeychainVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        _ = self;
        try checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, secret.name);
        try runSecretToolStore(allocator, io, keychainName, secret.type, secret.value);
    }

    //
    // Returns all photosphere secrets from the Secret Service.
    // Reads type from the secrettype attribute and value from a per-entry lookup.
    //
    pub fn list(self: *LinuxKeychainVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        _ = self;
        try checkTool(allocator, io);
        const output = runSecretToolSearchAll(allocator, io) catch {
            return &.{};
        };

        const entries = try parseSearchOutput(allocator, output);
        var secrets: std.ArrayList(ISecret) = .empty;

        for (entries) |entry| {
            const name = fromKeychainName(entry.account);
            const value = runCommand(allocator, io, &.{ SECRET_TOOL, "lookup", "service", KEYCHAIN_SERVICE, "account", entry.account }) catch {
                continue;
            };
            if (value.len == 0) {
                continue;
            }
            try secrets.append(allocator, .{ .name = name, .type = entry.secretType, .value = value });
        }

        return secrets.toOwnedSlice(allocator);
    }

    // Not ported: delete, checkPrereqs (not used by psi replicate or psi verify).

    //
    // IVault.get for this implementation.
    //
    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        const self: *LinuxKeychainVault = @ptrCast(@alignCast(ptr));
        return self.get(allocator, io, name);
    }

    //
    // IVault.set for this implementation.
    //
    fn setErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        const self: *LinuxKeychainVault = @ptrCast(@alignCast(ptr));
        return self.set(allocator, io, secret);
    }

    //
    // IVault.list for this implementation.
    //
    fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        const self: *LinuxKeychainVault = @ptrCast(@alignCast(ptr));
        return self.list(allocator, io);
    }
};
