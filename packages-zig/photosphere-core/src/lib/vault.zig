//
// The vault messages: vault-get, vault-set, vault-delete and vault-list. Each opens the default vault (getVault(getDefaultVaultType()))
// and does what its name says.
//
// Each is a task type, because a keychain answers by asking the operating system, which can take a while and can show the user a
// prompt, and the thread that handles the page's messages must not wait for that.
//
// What the page sees is JSON: vault-get replies with the secret, or null for a name that is not in the vault, and vault-set and
// vault-delete reply with null.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const ISecret = vault_zig.vault.ISecret;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// The name of a secret, which the page sends as the whole payload of vault-get and vault-delete.
//
fn secretName(data: std.json.Value) ![]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The request needs the name of a secret.", .{});
    }
    return data.string;
}

//
// vault-get: the payload is the name of a secret. The reply is the secret, or null when there is none of that name.
//
fn vaultGet(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    const name = try secretName(data);
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), services.nativeCaller(&requester_storage));
    const secret = try vault.get(allocator, io, name);
    return try json.stringify(allocator, secret);
}

//
// vault-set: the payload is {name, type, value}, all strings. Creates the secret, or overwrites the one of that name.
//
fn vaultSet(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    const name = json.getString(data, "name") orelse {
        return utils.errors.throwError("The request needs the name of a secret.", .{});
    };
    const secret_type = json.getString(data, "type") orelse {
        return utils.errors.throwError("The secret needs a type.", .{});
    };
    const value = json.getString(data, "value") orelse {
        return utils.errors.throwError("The secret needs a value.", .{});
    };
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), services.nativeCaller(&requester_storage));
    try vault.set(allocator, io, ISecret{
        .name = name,
        .type = secret_type,
        .value = value,
    });
    return try allocator.dupe(u8, "null");
}

//
// vault-delete: the payload is the name of a secret. Deletes it, and does nothing when there is none of that name.
//
fn vaultDelete(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    const name = try secretName(data);
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), services.nativeCaller(&requester_storage));
    try vault.delete(allocator, io, name);
    return try allocator.dupe(u8, "null");
}

//
// vault-list: no payload. The reply is every secret in the vault, as an array.
//
fn vaultList(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    _ = data;
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), services.nativeCaller(&requester_storage));
    const secrets = try vault.list(allocator, io);
    return try json.stringify(allocator, secrets);
}

//
// The vault-get message's handler: vaultGet, with its errors logged.
//
pub const vaultGetHandler = logExceptions(vaultGet, "Error getting vault secret");

//
// The vault-set message's handler: vaultSet, with its errors logged.
//
pub const vaultSetHandler = logExceptions(vaultSet, "Error setting vault secret");

//
// The vault-delete message's handler: vaultDelete, with its errors logged.
//
pub const vaultDeleteHandler = logExceptions(vaultDelete, "Error deleting vault secret");

//
// The vault-list message's handler: vaultList, with its errors logged.
//
pub const vaultListHandler = logExceptions(vaultList, "Error listing vault secrets");

//
// The data of vault-list, which has none.
//
pub const NoRequest = struct {};

//
// vault-get: the data is the name of a secret, answered by the vault-get task. The response is the secret, or null.
//
pub fn vaultGetMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !ziggy.core.Response(?ISecret) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "vault-get",
            .data = try json.stringify(allocator, name),
        },
    };
}

//
// The data of vault-set.
//
pub const VaultSetRequest = struct {
    // The name of the secret.
    name: []const u8,
    // The kind of secret, such as "s3-credentials".
    type: []const u8,
    // The secret itself.
    value: []const u8,
};

//
// vault-set: answered by the vault-set task, which writes the secret. The response is null.
//
pub fn vaultSetMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: VaultSetRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "vault-set",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// vault-delete: the data is the name of a secret, answered by the vault-delete task. The response is null.
//
pub fn vaultDeleteMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "vault-delete",
            .data = try json.stringify(allocator, name),
        },
    };
}

//
// vault-list: answered by the vault-list task. The response is every secret in the vault.
//
pub fn vaultListMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response([]const ISecret) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "vault-list",
            .data = try json.stringify(allocator, request),
        },
    };
}
