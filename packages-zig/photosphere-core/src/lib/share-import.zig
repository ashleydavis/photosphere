//
// The import-share-payload message: imports what was
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
const json = ziggy.json;
const lan_share = api.lan_share;
const logExceptions = @import("log-exceptions.zig").logExceptions;

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
// nothing for that name. A request with no conflictResolutions at all is
// an error when a secret's name is taken.
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
// A payload of any other type is an error, because replying as if something had been imported would hide the failure.
//
fn importSharePayload(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const payload = if (data == .object) data.object.get("payload") else null;
    const payload_value = payload orelse {
        return utils.errors.throwError("The request needs the payload that was shared.", .{});
    };
    const payload_type = json.getString(payload_value, "type") orelse {
        return utils.errors.throwError("The shared payload does not say whether it is a database or a secret.", .{});
    };
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    const host = context.hostRequester(&requester_storage);
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
        const entry = try api.lan_share_receive.importDatabasePayload(arena, context.io(), database_payload, resolver, host);
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
        const save_name = json.getString(payload_value, "saveName") orelse {
            return utils.errors.throwError("The shared secret needs a name to be saved under.", .{});
        };
        try api.lan_share_receive.importSecretPayload(arena, context.io(), secret_payload, save_name, host);
        return try arena.dupe(u8, "null");
    }
    return utils.errors.throwError("The shared payload is of a type that cannot be imported.", .{});
}

//
// The import-share-payload message's handler: importSharePayload, with its errors logged.
//
pub const importSharePayloadHandler = logExceptions(importSharePayload, "Error importing share payload");

//
// The data of import-share-payload.
//
pub const ImportSharePayloadRequest = struct {
    // What was shared: a database or a secret, with its "type".
    payload: std.json.Value,
    // The page's choices for the incoming secrets whose names are already taken, keyed by secret name, or null when it made none.
    conflictResolutions: std.json.Value = .null,
};

//
// import-share-payload: answered by the import-share-payload task. The response is null.
//
pub fn importSharePayloadMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: ImportSharePayloadRequest) !ziggy.core.Answer(void) {
    _ = core;
    return .{
        .task = .{
            .task_type = "import-share-payload",
            .data = try json.stringify(arena, request),
        },
    };
}
