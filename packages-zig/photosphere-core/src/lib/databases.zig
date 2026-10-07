//
// The database list channels: get-databases, find-database, add-database, update-database, remove-database-entry,
// set-database-origin and list-s3-dirs, from the ipcMain handlers of apps/desktop/src/main.ts of the same names. They read and write
// databases.toml, and (for the last two) a database's .db/config.json and an S3 bucket.
//
// Each is a task type, because they read and write files and talk to S3, and the thread that handles the page's messages must not
// wait for that.
//
// What the page sees is what Electron sends back, in JSON: where Electron replies undefined (update-database, remove-database-entry,
// set-database-origin) the reply is null, find-database replies null for a name that is not there, and an entry's optional fields
// that are not set are left out.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api_zig = @import("api-zig");
const storage_zig = @import("storage-zig");
const vault_zig = @import("vault-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const databases_config = node_api.databases_config;
const IDatabaseEntry = databases_config.IDatabaseEntry;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const log = &utils.log.log;

//
// Reads a database entry from the JSON the page sends: name, description and path are required, the rest are left out when the
// page leaves them out.
//
// (Zig: a missing name, description or path is an error here, where TypeScript passes the object on and fails later, or not at all,
// because IDatabaseEntry cannot hold an absent required field.)
//
fn entryFromJson(data: std.json.Value) !IDatabaseEntry {
    const name = json_util.getString(data, "name") orelse {
        return utils.errors.throwError("The database needs a name.", .{});
    };
    const description = json_util.getString(data, "description") orelse {
        return utils.errors.throwError("The database needs a description.", .{});
    };
    const path = json_util.getString(data, "path") orelse {
        return utils.errors.throwError("The database needs a path.", .{});
    };
    return .{
        .name = name,
        .description = description,
        .path = path,
        .origin = json_util.getString(data, "origin"),
        .s3Key = json_util.getString(data, "s3Key"),
        .encryptionKey = json_util.getString(data, "encryptionKey"),
        .geocodingKey = json_util.getString(data, "geocodingKey"),
    };
}

//
// The name of a database, which the page sends as the whole payload of find-database and remove-database-entry.
//
fn databaseName(data: std.json.Value) ![]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The database needs a name.", .{});
    }
    return data.string;
}

//
// Gets a string property of a parsed JSON object (null when it is absent or not a string, like `parsed.key` reading undefined).
//
fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

//
// Reads S3 credentials from the value of a vault secret, which holds them as JSON (the JSON.parse of main.ts). A key the secret does
// not hold reads as "" for the two that are required, as in resolveStorageCredentials, because IS3Credentials cannot carry an absent one.
//
// (Zig: the message of a value that is not JSON is this sentence plus the parser's error name, where JSON.parse's SyntaxError carries
// V8's own wording, which the Zig parser does not produce. A secret that is JSON null is an error, as `parsed.region` is a TypeError
// in TypeScript; any other JSON value that is not an object reads every key as absent, as it does there.)
//
fn s3CredentialsFromSecret(allocator: std.mem.Allocator, secretValue: []const u8) !IS3Credentials {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, secretValue, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        return utils.errors.throwError("The secret that holds the S3 credentials is not valid JSON ({s}).", .{@errorName(err)});
    };
    if (parsed == .null) {
        return utils.errors.throwError("The secret that holds the S3 credentials is JSON null, so it holds no credentials.", .{});
    }
    const parsedObject = switch (parsed) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    return .{
        .region = jsonString(parsedObject, "region"),
        .accessKeyId = jsonString(parsedObject, "accessKeyId") orelse "",
        .secretAccessKey = jsonString(parsedObject, "secretAccessKey") orelse "",
        .endpoint = jsonString(parsedObject, "endpoint"),
    };
}

//
// The storage of a database and the entry for it in the databases list, if there is one.
//
pub const IOpenedDatabaseStorage = struct {
    // The entry in the databases list whose path is the database's, or null when the database is not in the list.
    entry: ?IDatabaseEntry,
    // The storage of the database, with no encryption or other wrapper over it.
    rawStorage: storage_zig.storage.IStorage,
};

//
// Opens the raw storage of the database at a path, using the S3 credentials in the vault secret the database's entry names when it
// has one. set-database-origin and notify-database-opened in main.ts each repeat this block.
//
pub fn openDatabaseStorage(allocator: std.mem.Allocator, io: std.Io, databases: []const IDatabaseEntry, database_path: []const u8) !IOpenedDatabaseStorage {
    const vault = try vault_zig.get_vault.getVault(vault_zig.get_vault.getDefaultVaultType());
    var database_entry: ?IDatabaseEntry = null;
    for (databases) |existing_entry| {
        if (std.mem.eql(u8, existing_entry.path, database_path)) {
            database_entry = existing_entry;
            break;
        }
    }
    var s3_credentials: ?IS3Credentials = null;
    if (database_entry) |found_entry| {
        if (found_entry.s3Key) |s3_key| {
            if (s3_key.len > 0) {
                const s3_secret = try vault.get(allocator, io, s3_key);
                if (s3_secret) |secret| {
                    s3_credentials = try s3CredentialsFromSecret(allocator, secret.value);
                }
            }
        }
    }
    const created = try storage_zig.storage_factory.createStorage(allocator, io, database_path, s3_credentials, null);
    return .{
        .entry = database_entry,
        .rawStorage = created.rawStorage,
    };
}

//
// remove-database-entry: the payload is a database name. Removes the entry and the name from the recents. The secrets are
// independent and are managed on the secrets page.
//
pub fn removeDatabaseEntryHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const name = try databaseName(data);
    try databases_config.removeDatabaseEntry(context.arena, context.io(), name);
    return try context.arena.dupe(u8, "null");
}

//
// find-database: the payload is a database name. The reply is the entry (matched case-insensitively), or null when there is none.
//
pub fn findDatabaseHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const name = try databaseName(data);
    const found = try databases_config.findDatabase(context.arena, context.io(), name);
    return try json_util.stringify(context.arena, found);
}

//
// get-databases: no payload. The reply is every configured database entry, as an array.
//
pub fn getDatabasesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const databases = try databases_config.getDatabases(context.arena, context.io());
    return try json_util.stringify(context.arena, databases);
}

//
// add-database: the payload is a database entry. Adds it, and replies with the entry.
//
// (Zig: the reply is the entry as read into IDatabaseEntry, so a key of the page's object that is not a field of the entry is not
// echoed back, where TypeScript returns the object it was given untouched. The entry type has no other keys.)
//
pub fn addDatabaseHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const entry = try entryFromJson(data);
    try databases_config.addDatabaseEntry(context.arena, context.io(), entry);
    log.event("Database entry added");
    return try json_util.stringify(context.arena, entry);
}

//
// update-database: the payload is {originalName, entry}. Updates the entry that originalName names, renaming it if the entry's name
// differs.
//
pub fn updateDatabaseHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const original_name = json_util.getString(data, "originalName") orelse {
        return utils.errors.throwError("The database needs a name.", .{});
    };
    if (data != .object) {
        return utils.errors.throwError("The request needs the database entry to save.", .{});
    }
    const entry_data = data.object.get("entry") orelse {
        return utils.errors.throwError("The request needs the database entry to save.", .{});
    };
    const entry = try entryFromJson(entry_data);
    try databases_config.updateDatabaseEntry(context.arena, context.io(), original_name, entry);
    return try context.arena.dupe(u8, "null");
}

//
// Writes the origin into a database's .db/config.json, or removes it when origin is null. updateDatabaseConfig in api-zig can only
// set a key (an origin of null leaves the existing one alone), where `{ ...existing, origin: undefined }` in TypeScript clears it
// when the file is written, so a null origin is cleared here by loading the config, taking the key out and saving it.
//
fn writeDatabaseOrigin(context: *TaskContext, rawStorage: storage_zig.storage.IStorage, origin: ?[]const u8) !void {
    if (origin != null) {
        try api_zig.database_config.updateDatabaseConfig(context.arena, context.io(), rawStorage, .{
            .origin = origin,
        });
        return;
    }
    const existing = try api_zig.database_config.loadDatabaseConfig(context.arena, context.io(), rawStorage);
    var config: std.json.ObjectMap = .empty;
    if (existing) |existing_value| {
        if (existing_value == .object) {
            var iterator = existing_value.object.iterator();
            while (iterator.next()) |config_entry| {
                if (!std.mem.eql(u8, config_entry.key_ptr.*, "origin")) {
                    try config.put(context.arena, config_entry.key_ptr.*, config_entry.value_ptr.*);
                }
            }
        }
    }
    try api_zig.database_config.saveDatabaseConfig(context.arena, context.io(), rawStorage, std.json.Value{
        .object = config,
    });
}

//
// set-database-origin: the payload is {databasePath, origin}, where a missing origin clears it. Writes the origin to the database's
// .db/config.json, and to the database's entry when it has one with a different origin.
//
pub fn setDatabaseOriginHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const database_path = json_util.getString(data, "databasePath") orelse {
        return utils.errors.throwError("The database needs a path.", .{});
    };
    const origin = json_util.getString(data, "origin");
    const databases = try databases_config.getDatabases(context.arena, context.io());
    const opened = try openDatabaseStorage(context.arena, context.io(), databases, database_path);
    try writeDatabaseOrigin(context, opened.rawStorage, origin);
    if (opened.entry) |found_entry| {
        if (!optionalStringsEqual(found_entry.origin, origin)) {
            var updated_entry = found_entry;
            updated_entry.origin = origin;
            try databases_config.updateDatabaseEntry(context.arena, context.io(), found_entry.name, updated_entry);
        }
    }
    log.event(try std.fmt.allocPrint(context.arena, "Database origin updated for {s}", .{node_utils.path.basename(database_path)}));
    return try context.arena.dupe(u8, "null");
}

//
// Whether two optional strings are both absent or both the same text (the `!==` between two string-or-undefined values).
//
fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) {
        return left == null and right == null;
    }
    return std.mem.eql(u8, left.?, right.?);
}

//
// list-s3-dirs: the payload is {s3Key, bucket, prefix}. The reply is the names of the directories under the prefix in the bucket
// (at most one page of them), or an empty array when the vault holds no secret of that name.
//
pub fn listS3DirsHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const s3_key = json_util.getString(data, "s3Key") orelse {
        return utils.errors.throwError("The request needs the name of the secret that holds the S3 credentials.", .{});
    };
    const bucket = json_util.getString(data, "bucket") orelse {
        return utils.errors.throwError("The request needs the name of the S3 bucket.", .{});
    };
    const prefix = json_util.getString(data, "prefix") orelse {
        return utils.errors.throwError("The request needs the folder to list in the S3 bucket.", .{});
    };
    const vault = try vault_zig.get_vault.getVault(vault_zig.get_vault.getDefaultVaultType());
    const secret = try vault.get(context.arena, context.io(), s3_key);
    const found_secret = secret orelse {
        return try context.arena.dupe(u8, "[]");
    };
    const credentials = try s3CredentialsFromSecret(context.arena, found_secret.value);
    var storage = CloudStorage.init(context.io(), bucket, credentials);
    const path = try std.fmt.allocPrint(context.arena, "{s}/{s}", .{ bucket, prefix });
    const result = try storage.listDirs(context.arena, context.io(), path, 100, null);
    return try json_util.stringify(context.arena, result.names);
}
