const std = @import("std");
const utils = @import("utils-zig");
const vault_module = @import("vault.zig");
const keychain_types = @import("keychain-types.zig");
const ISecret = vault_module.ISecret;
const IVault = vault_module.IVault;
const IPrereqCheckResult = vault_module.IPrereqCheckResult;
const IKeychainPayload = keychain_types.IKeychainPayload;
const toKeychainName = keychain_types.toKeychainName;
const fromKeychainName = keychain_types.fromKeychainName;
const runCommand = keychain_types.runCommand;
const errors = utils.errors;

//
// The fixed path to the macOS security CLI tool.
//
const SECURITY_TOOL = "/usr/bin/security";

//
// The keychain service name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Returns the first capture of the pattern `"<tag>"<blob>="([^"]+)"` in text, or null when there is no match.
//
fn matchBlobAttribute(text: []const u8, comptime tag: []const u8) ?[]const u8 {
    const prefix = "\"" ++ tag ++ "\"<blob>=\"";
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, prefix)) |match_index| {
        const value_start = match_index + prefix.len;
        if (std.mem.indexOfScalarPos(u8, text, value_start, '"')) |value_end| {
            if (value_end > value_start) {
                return text[value_start..value_end];
            }
        }
        search_start = match_index + 1;
    }
    return null;
}

//
// Parses the output of `security dump-keychain` and returns the account names
// of all entries whose service matches KEYCHAIN_SERVICE and whose account name
// starts with the psi- prefix.
//
// Each entry block in the dump output starts with a "keychain:" line and
// contains attribute lines of the form `"tag"<type>="value"`.
// Attribute metadata (names, labels) is returned without auth prompts;
// only secret values require user authorization.
//
pub fn parseKeychainDump(allocator: std.mem.Allocator, output: []const u8) ![][]const u8 {
    var keychainNames: std.ArrayList([]const u8) = .empty;

    // output.split(/^keychain:/m): the blocks between occurrences of "keychain:" at the start of a line.
    var blocks: std.ArrayList([]const u8) = .empty;
    const separator = "keychain:";
    var block_start: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_start, separator)) |match_index| {
        const at_line_start = match_index == 0 or output[match_index - 1] == '\n';
        if (at_line_start) {
            try blocks.append(allocator, output[block_start..match_index]);
            block_start = match_index + separator.len;
        }
        search_start = match_index + 1;
    }
    try blocks.append(allocator, output[block_start..]);

    for (blocks.items) |block| {
        const svceMatch = matchBlobAttribute(block, "svce");
        const acctMatch = matchBlobAttribute(block, "acct");
        if (svceMatch != null and std.mem.eql(u8, svceMatch.?, KEYCHAIN_SERVICE) and
            acctMatch != null and std.mem.startsWith(u8, acctMatch.?, keychain_types.KEYCHAIN_PREFIX))
        {
            try keychainNames.append(allocator, acctMatch.?);
        }
    }
    return keychainNames.toOwnedSlice(allocator);
}

//
// A vault implementation that persists secrets in the macOS Keychain using
// the /usr/bin/security CLI tool.
//
// Listing uses `security dump-keychain` filtered to our psi- prefix on the
// account field, which returns metadata without triggering auth prompts.
// This avoids any index file and keeps the vault self-consistent.
//
// Every secret name stored in the keychain is prefixed with "psi-" to make
// photosphere entries clearly identifiable in the Keychain Access UI.
//
pub const MacOSKeychainVault = struct {
    //
    // Set to true once the tool availability check has been performed.
    //
    toolChecked: std.atomic.Value(bool),

    //
    // Creates the vault.
    //
    pub fn init() MacOSKeychainVault {
        return .{ .toolChecked = std.atomic.Value(bool).init(false) };
    }

    //
    // Gets the IVault interface for this vault.
    //
    pub fn vault(self: *MacOSKeychainVault) IVault {
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
    // Checks that /usr/bin/security is present and executable.
    // Returns ok=true on success, or ok=false with an error message on failure.
    //
    pub fn checkPrereqs(self: *MacOSKeychainVault, allocator: std.mem.Allocator, io: std.Io) IPrereqCheckResult {
        _ = self;
        if (runCommand(allocator, io, &.{ SECURITY_TOOL, "version" })) |_| {
            return .{ .ok = true, .message = null };
        }
        else |_| {
            return .{
                .ok = false,
                .message = "macOS Keychain tool not found at " ++ SECURITY_TOOL ++ ". This tool is bundled with macOS and should always be present.",
            };
        }
    }

    //
    // Verifies that the security CLI tool is available, logging its version.
    // Throws a helpful error if the tool is not found.
    //
    fn checkTool(self: *MacOSKeychainVault, allocator: std.mem.Allocator, io: std.Io) !void {
        if (self.toolChecked.swap(true, .acq_rel)) {
            return;
        }
        const result = self.checkPrereqs(allocator, io);
        if (!result.ok) {
            return errors.throwError("{s}", .{result.message.?});
        }
        _ = try runCommand(allocator, io, &.{ SECURITY_TOOL, "version" });
    }

    //
    // Retrieves a secret by name from the macOS Keychain.
    // Returns null if no secret with that name exists.
    //
    pub fn get(self: *MacOSKeychainVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        try self.checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, name);
        const raw = runCommand(allocator, io, &.{ SECURITY_TOOL, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", keychainName, "-w" }) catch {
            return null;
        };
        const payload = std.json.parseFromSliceLeaky(IKeychainPayload, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            return errors.throwError("JSON Parse error: {s}", .{@errorName(err)});
        };
        return .{ .name = name, .type = payload.type, .value = payload.value };
    }

    //
    // Creates or overwrites a secret in the macOS Keychain.
    //
    pub fn set(self: *MacOSKeychainVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        try self.checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, secret.name);
        const payload: IKeychainPayload = .{ .type = secret.type, .value = secret.value };
        const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        _ = try runCommand(allocator, io, &.{ SECURITY_TOOL, "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", keychainName, "-w", json });
    }

    //
    // Returns all photosphere secrets in the macOS Keychain by parsing
    // `security dump-keychain` output for entries matching our service name
    // and psi- account prefix, then fetching each secret individually.
    //
    pub fn list(self: *MacOSKeychainVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        try self.checkTool(allocator, io);
        const output = runCommand(allocator, io, &.{ SECURITY_TOOL, "dump-keychain" }) catch {
            return &.{};
        };
        const keychainNames = try parseKeychainDump(allocator, output);
        var secrets: std.ArrayList(ISecret) = .empty;
        for (keychainNames) |keychainName| {
            const name = fromKeychainName(keychainName);
            const secret = try self.get(allocator, io, name);
            if (secret) |found_secret| {
                try secrets.append(allocator, found_secret);
            }
        }
        return secrets.toOwnedSlice(allocator);
    }

    // Not ported: delete (not used by psi replicate or psi verify).

    //
    // IVault.get for this implementation.
    //
    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        const self: *MacOSKeychainVault = @ptrCast(@alignCast(ptr));
        return self.get(allocator, io, name);
    }

    //
    // IVault.set for this implementation.
    //
    fn setErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        const self: *MacOSKeychainVault = @ptrCast(@alignCast(ptr));
        return self.set(allocator, io, secret);
    }

    //
    // IVault.list for this implementation.
    //
    fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        const self: *MacOSKeychainVault = @ptrCast(@alignCast(ptr));
        return self.list(allocator, io);
    }
};

//
// Re-export the prefix constant so callers can refer to it without importing
// keychain-types directly.
//
pub const KEYCHAIN_PREFIX = keychain_types.KEYCHAIN_PREFIX;
