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
// The keychain resource name used for all photosphere secrets.
//
const KEYCHAIN_SERVICE = "photosphere";

//
// Set to true once the tool availability check has been performed.
//
var toolChecked = std.atomic.Value(bool).init(false);

//
// Checks that PowerShell is available and executable.
// Returns ok=true on success, or ok=false with an error message on failure.
//
fn checkPrereqsOnce(allocator: std.mem.Allocator, io: std.Io) IPrereqCheckResult {
    if (runCommand(allocator, io, &.{ "powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()" })) |_| {
        return .{ .ok = true, .message = null };
    }
    else |_| {
        return .{
            .ok = false,
            .message = "PowerShell is not available. PowerShell is required to use the Windows Credential Vault. Install PowerShell from https://aka.ms/powershell",
        };
    }
}

//
// Checks that PowerShell is available, logging its version.
// Throws a helpful error if PowerShell is not found.
//
fn checkTool(allocator: std.mem.Allocator, io: std.Io) !void {
    if (toolChecked.swap(true, .acq_rel)) {
        return;
    }
    const result = checkPrereqsOnce(allocator, io);
    if (!result.ok) {
        return errors.throwError("{s}", .{result.message.?});
    }
    _ = try runCommand(allocator, io, &.{ "powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()" });
}

//
// Forgets that the tool availability check has been performed (tests only; TypeScript tests get a
// fresh module per test file instead).
//
pub fn resetToolChecked() void {
    toolChecked.store(false, .release);
}

//
// Preamble that forces Windows PowerShell to load the WinRT projections for
// the Windows.Security.Credentials namespace. Without this, New-Object fails
// with "Cannot find type [Windows.Security.Credentials.PasswordVault]".
//
const WINRT_PREAMBLE = "[void][Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime];[void][Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime];";

//
// Runs a PowerShell script and returns its trimmed stdout.
//
fn runPowerShell(allocator: std.mem.Allocator, io: std.Io, script: []const u8) ![]const u8 {
    const command = try std.mem.concat(allocator, u8, &.{ WINRT_PREAMBLE, script });
    return runCommand(allocator, io, &.{ "powershell", "-NoProfile", "-Command", command });
}

//
// Escapes single quotes for a PowerShell single-quoted string (TypeScript: `.replace(/'/g, "''")`).
//
fn escapeSingleQuotes(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, text, "'", "''");
}

//
// A vault implementation that persists secrets in the Windows Credential Vault
// using PowerShell and the Windows.Security.Credentials.PasswordVault API.
//
// Every secret name stored is prefixed with "psi-" to make photosphere entries
// clearly identifiable.  Native listing means no index file is needed.
//
pub const WindowsKeychainVault = struct {
    // Unused. Present because an IVault must point at a value with an address.
    unused: u8,

    //
    // Creates the vault.
    //
    pub fn init() WindowsKeychainVault {
        return .{ .unused = 0 };
    }

    //
    // Gets the IVault interface for this vault.
    //
    pub fn vault(self: *WindowsKeychainVault) IVault {
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
    // Retrieves a secret by name from the Windows Credential Vault.
    // Returns null if no secret with that name exists.
    //
    pub fn get(self: *WindowsKeychainVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        _ = self;
        try checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, name);
        const escapedService = try escapeSingleQuotes(allocator, KEYCHAIN_SERVICE);
        const escapedAccount = try escapeSingleQuotes(allocator, keychainName);
        const script = try std.fmt.allocPrint(allocator,
            \\$vault = New-Object Windows.Security.Credentials.PasswordVault;
            \\try {{
            \\    $cred = $vault.Retrieve('{s}', '{s}');
            \\    $cred.RetrievePassword();
            \\    Write-Output $cred.Password
            \\}} catch {{
            \\    exit 1
            \\}}
        , .{ escapedService, escapedAccount });
        const raw = runPowerShell(allocator, io, script) catch {
            return null;
        };
        if (raw.len == 0) {
            return null;
        }
        const payload = std.json.parseFromSliceLeaky(IKeychainPayload, allocator, raw, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            return errors.throwError("JSON Parse error: {s}", .{@errorName(err)});
        };
        return .{ .name = name, .type = payload.type, .value = payload.value };
    }

    //
    // Creates or overwrites a secret in the Windows Credential Vault.
    //
    pub fn set(self: *WindowsKeychainVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        _ = self;
        try checkTool(allocator, io);
        const keychainName = try toKeychainName(allocator, secret.name);
        const payload: IKeychainPayload = .{ .type = secret.type, .value = secret.value };
        const json = try escapeSingleQuotes(allocator, try std.json.Stringify.valueAlloc(allocator, payload, .{}));
        const escapedService = try escapeSingleQuotes(allocator, KEYCHAIN_SERVICE);
        const escapedAccount = try escapeSingleQuotes(allocator, keychainName);
        const script = try std.fmt.allocPrint(allocator,
            \\$vault = New-Object Windows.Security.Credentials.PasswordVault;
            \\try {{
            \\    $existing = $vault.Retrieve('{s}', '{s}');
            \\    $vault.Remove($existing);
            \\}} catch {{}}
            \\$cred = New-Object Windows.Security.Credentials.PasswordCredential('{s}', '{s}', '{s}');
            \\$vault.Add($cred);
        , .{ escapedService, escapedAccount, escapedService, escapedAccount, json });
        _ = try runPowerShell(allocator, io, script);
    }

    //
    // Returns all photosphere secrets from the Windows Credential Vault by
    // searching for entries under the photosphere resource.
    //
    pub fn list(self: *WindowsKeychainVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        try checkTool(allocator, io);
        const escapedService = try escapeSingleQuotes(allocator, KEYCHAIN_SERVICE);
        const script = try std.fmt.allocPrint(allocator,
            \\$vault = New-Object Windows.Security.Credentials.PasswordVault;
            \\try {{
            \\    $creds = $vault.FindAllByResource('{s}');
            \\    foreach ($cred in $creds) {{
            \\        Write-Output $cred.UserName
            \\    }}
            \\}} catch {{}}
        , .{escapedService});
        const output = runPowerShell(allocator, io, script) catch {
            return &.{};
        };

        var secrets: std.ArrayList(ISecret) = .empty;
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const keychainName = std.mem.trim(u8, line, keychain_types.whitespace);
            if (std.mem.startsWith(u8, keychainName, "psi-")) {
                const name = fromKeychainName(keychainName);
                const secret = try self.get(allocator, io, name);
                if (secret) |found_secret| {
                    try secrets.append(allocator, found_secret);
                }
            }
        }
        return secrets.toOwnedSlice(allocator);
    }

    // Not ported: delete, checkPrereqs (not used by psi replicate or psi verify).

    //
    // IVault.get for this implementation.
    //
    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        const self: *WindowsKeychainVault = @ptrCast(@alignCast(ptr));
        return self.get(allocator, io, name);
    }

    //
    // IVault.set for this implementation.
    //
    fn setErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        const self: *WindowsKeychainVault = @ptrCast(@alignCast(ptr));
        return self.set(allocator, io, secret);
    }

    //
    // IVault.list for this implementation.
    //
    fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        const self: *WindowsKeychainVault = @ptrCast(@alignCast(ptr));
        return self.list(allocator, io);
    }
};
