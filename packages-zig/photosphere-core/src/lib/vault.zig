//
// The vault channels: vault-get, vault-set, vault-delete and vault-list. Each opens the default vault (getVault(getDefaultVaultType()))
// and does what its name says.
//
// Each is a task type, because a keychain answers by asking the operating system, which can take a while and can show the user a
// prompt, and the thread that handles the page's messages must not wait for that.
//
// What the page sees is JSON: vault-get replies with the secret, or null for a name that is not in the vault, and vault-set and
// vault-delete reply with null.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
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
fn vaultGet(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const name = try secretName(data);
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(context.arena, vault_zig.get_vault.getDefaultVaultType(), context.hostRequester(&requester_storage));
    const secret = try vault.get(context.arena, context.io(), name);
    return try json_util.stringify(context.arena, secret);
}

//
// vault-set: the payload is {name, type, value}, all strings. Creates the secret, or overwrites the one of that name.
//
fn vaultSet(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const name = json_util.getString(data, "name") orelse {
        return utils.errors.throwError("The request needs the name of a secret.", .{});
    };
    const secret_type = json_util.getString(data, "type") orelse {
        return utils.errors.throwError("The secret needs a type.", .{});
    };
    const value = json_util.getString(data, "value") orelse {
        return utils.errors.throwError("The secret needs a value.", .{});
    };
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(context.arena, vault_zig.get_vault.getDefaultVaultType(), context.hostRequester(&requester_storage));
    try vault.set(context.arena, context.io(), ISecret{
        .name = name,
        .type = secret_type,
        .value = value,
    });
    return try context.arena.dupe(u8, "null");
}

//
// vault-delete: the payload is the name of a secret. Deletes it, and does nothing when there is none of that name.
//
fn vaultDelete(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const name = try secretName(data);
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(context.arena, vault_zig.get_vault.getDefaultVaultType(), context.hostRequester(&requester_storage));
    try vault.delete(context.arena, context.io(), name);
    return try context.arena.dupe(u8, "null");
}

//
// vault-list: no payload. The reply is every secret in the vault, as an array.
//
fn vaultList(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(context.arena, vault_zig.get_vault.getDefaultVaultType(), context.hostRequester(&requester_storage));
    const secrets = try vault.list(context.arena, context.io());
    return try json_util.stringify(context.arena, secrets);
}

//
// The vault-get channel's handler: vaultGet, with its errors logged.
//
pub const vaultGetHandler = logExceptions(vaultGet, "Error getting vault secret");

//
// The vault-set channel's handler: vaultSet, with its errors logged.
//
pub const vaultSetHandler = logExceptions(vaultSet, "Error setting vault secret");

//
// The vault-delete channel's handler: vaultDelete, with its errors logged.
//
pub const vaultDeleteHandler = logExceptions(vaultDelete, "Error deleting vault secret");

//
// The vault-list channel's handler: vaultList, with its errors logged.
//
pub const vaultListHandler = logExceptions(vaultList, "Error listing vault secrets");
