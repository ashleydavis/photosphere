//
// The import-share-payload channel, from the ipcMain handler of the same name in apps/desktop/src/main.ts: imports what was
// received from another device, a database (its secrets go to the vault and its entry to the databases list) or a single secret.
//
// It is a task type, because it writes to the vault and to a file.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const lan_share = api.lan_share;

//
// What the page chose to do about each of the incoming secrets whose name is already taken, as it sent them: the payload's
// conflictResolutions object, keyed by secret name.
//
const IConflictChoices = struct {
    // The page's conflictResolutions object.
    resolutions: std.json.Value,
};

//
// The conflict resolver of the handler: the resolution the page chose for the secret, or replacing it when the page chose
// nothing for that name (`conflictResolutions[secretName] ?? { action: 'replace' }`). A request with no conflictResolutions at all is
// an error when a secret's name is taken, as reading a key of undefined is a TypeError in TypeScript.
//
fn resolveFromChoices(context: ?*anyopaque, allocator: std.mem.Allocator, secret_name: []const u8, secret_type: []const u8) anyerror!lan_share.IConflictResolution {
    _ = secret_type;
    const choices: *const IConflictChoices = @ptrCast(@alignCast(context.?));
    if (choices.resolutions == .null) {
        return utils.errors.throwError("The request needs the choices made for the secrets whose names are already taken.", .{});
    }
    if (choices.resolutions != .object) {
        return .{
            .action = .replace,
        };
    }
    const chosen = choices.resolutions.object.get(secret_name) orelse {
        return .{
            .action = .replace,
        };
    };
    return try std.json.parseFromValueLeaky(lan_share.IConflictResolution, allocator, chosen, .{
        .ignore_unknown_fields = true,
    });
}

//
// import-share-payload: the payload is {payload, conflictResolutions}. A database payload (type "database") has its secrets
// written to the vault, under the names the resolutions allow, and its entry added to the databases list. A secret payload
// (type "secret", with the name to save it under in saveName) is written to the vault. The reply is null.
//
// (Zig: a payload of any other type is an error, where TypeScript did nothing and replied as if it had imported something.)
//
pub fn importSharePayloadHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const payload = if (data == .object) data.object.get("payload") else null;
    const payload_value = payload orelse {
        return utils.errors.throwError("The request needs the payload that was shared.", .{});
    };
    const payload_type = json_util.getString(payload_value, "type") orelse {
        return utils.errors.throwError("The shared payload does not say whether it is a database or a secret.", .{});
    };
    if (std.mem.eql(u8, payload_type, "database")) {
        const database_payload = try std.json.parseFromValueLeaky(lan_share.IDatabaseSharePayload, arena, payload_value, .{
            .ignore_unknown_fields = true,
        });
        var choices: IConflictChoices = .{
            .resolutions = data.object.get("conflictResolutions") orelse .null,
        };
        const resolver: lan_share.ConflictResolver = .{
            .context = &choices,
            .function = resolveFromChoices,
        };
        const entry = try api.lan_share_receive.importDatabasePayload(arena, context.io(), database_payload, resolver);
        try node_api.databases_config.addDatabaseEntry(arena, context.io(), .{
            .name = entry.name,
            .description = entry.description,
            .path = entry.path,
            .origin = entry.origin,
            .s3Key = entry.s3Key,
            .encryptionKey = entry.encryptionKey,
            .geocodingKey = entry.geocodingKey,
        });
        return try arena.dupe(u8, "null");
    }
    if (std.mem.eql(u8, payload_type, "secret")) {
        const secret_payload = try std.json.parseFromValueLeaky(lan_share.ISecretSharePayload, arena, payload_value, .{
            .ignore_unknown_fields = true,
        });
        const save_name = json_util.getString(payload_value, "saveName") orelse {
            return utils.errors.throwError("The shared secret needs a name to be saved under.", .{});
        };
        try api.lan_share_receive.importSecretPayload(arena, context.io(), secret_payload, save_name);
        return try arena.dupe(u8, "null");
    }
    return utils.errors.throwError("The shared payload is of a type that cannot be imported.", .{});
}
