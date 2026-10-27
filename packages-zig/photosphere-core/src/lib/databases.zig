//
// The database list messages: get-databases, find-database, add-database, update-database, remove-database-entry,
// set-database-origin and list-s3-dirs. They read and write
// databases.toml, and (for the last two) a database's .db/config.json and an S3 bucket.
//
// Each is a task type, because they read and write files and talk to S3, and the thread that handles the page's messages must not
// wait for that.
//
// What the page sees is JSON: update-database, remove-database-entry and set-database-origin reply null,
// find-database replies null for a name that is not there, and an entry's optional fields
// that are not set are left out.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api_zig = @import("api-zig");
const storage_zig = @import("storage-zig");
const vault_zig = @import("vault-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const databases_config = node_api.databases_config;
const IDatabaseEntry = databases_config.IDatabaseEntry;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// Reads a database entry from the JSON the page sends: name, description and path are required, the rest are left out when the
// page leaves them out.
//
// A missing name, description or path is an error, because IDatabaseEntry cannot hold an absent required field.
//
fn entryFromJson(data: std.json.Value) !IDatabaseEntry {
    const name = json.getString(data, "name") orelse {
        return utils.errors.throwError("The database needs a name.", .{});
    };
    const description = json.getString(data, "description") orelse {
        return utils.errors.throwError("The database needs a description.", .{});
    };
    const path = json.getString(data, "path") orelse {
        return utils.errors.throwError("The database needs a path.", .{});
    };
    return .{
        .name = name,
        .description = description,
        .path = path,
        .origin = json.getString(data, "origin"),
        .s3Key = json.getString(data, "s3Key"),
        .encryptionKey = json.getString(data, "encryptionKey"),
        .geocodingKey = json.getString(data, "geocodingKey"),
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
// Reads S3 credentials from the value of a vault secret, which holds them as JSON. A key the secret does
// not hold reads as "" for the two that are required, as in resolveStorageCredentials, because IS3Credentials cannot carry an absent one.
//
// The message of a value that is not JSON is a sentence plus the parser's error name. A secret that is JSON null is an error;
// any other JSON value that is not an object reads every key as absent.
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
// has one. set-database-origin and notify-database-opened each need this block.
//
pub fn openDatabaseStorage(allocator: std.mem.Allocator, io: std.Io, databases: []const IDatabaseEntry, database_path: []const u8, native_caller: ?utils.native_caller.INativeCaller) !IOpenedDatabaseStorage {
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), native_caller);
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
fn removeDatabaseEntry(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    const name = try databaseName(data);
    try databases_config.removeDatabaseEntry(allocator, io, name);
    return try allocator.dupe(u8, "null");
}

//
// find-database: the payload is a database name. The reply is the entry (matched case-insensitively), or null when there is none.
//
fn findDatabase(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    const name = try databaseName(data);
    const found = try databases_config.findDatabase(allocator, io, name);
    return try json.stringify(allocator, found);
}

//
// get-databases: no payload. The reply is every configured database entry, as an array.
//
fn getDatabases(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    _ = data;
    const databases = try databases_config.getDatabases(allocator, io);
    return try json.stringify(allocator, databases);
}

//
// add-database: the payload is a database entry. Adds it, and replies with the entry.
//
// The reply is the entry as read into IDatabaseEntry, so a key of the page's object that is not a field of the entry is not
// echoed back. The entry type has no other keys.
//
fn addDatabase(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const log = services.log;
    _ = timers;
    _ = context;
    const entry = try entryFromJson(data);
    try databases_config.addDatabaseEntry(allocator, io, entry);
    log.event("Database entry added");
    return try json.stringify(allocator, entry);
}

//
// update-database: the payload is {originalName, entry}. Updates the entry that originalName names, renaming it if the entry's name
// differs.
//
fn updateDatabase(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    const original_name = json.getString(data, "originalName") orelse {
        return utils.errors.throwError("The database needs a name.", .{});
    };
    if (data != .object) {
        return utils.errors.throwError("The request needs the database entry to save.", .{});
    }
    const entry_data = data.object.get("entry") orelse {
        return utils.errors.throwError("The request needs the database entry to save.", .{});
    };
    const entry = try entryFromJson(entry_data);
    try databases_config.updateDatabaseEntry(allocator, io, original_name, entry);
    return try allocator.dupe(u8, "null");
}

//
// Writes the origin into a database's .db/config.json, or removes it when origin is null. updateDatabaseConfig in api-zig can only
// set a key (an origin of null leaves the existing one alone), so a null origin is cleared here by loading the config, taking
// the key out and saving it.
//
fn writeDatabaseOrigin(io: std.Io, log: ILog, allocator: std.mem.Allocator, rawStorage: storage_zig.storage.IStorage, origin: ?[]const u8) !void {
    if (origin != null) {
        try api_zig.database_config.updateDatabaseConfig(allocator, io, log, rawStorage, .{
            .origin = origin,
        });
        return;
    }
    const existing = try api_zig.database_config.loadDatabaseConfig(allocator, io, log, rawStorage);
    var config: std.json.ObjectMap = .empty;
    if (existing) |existing_value| {
        if (existing_value == .object) {
            var iterator = existing_value.object.iterator();
            while (iterator.next()) |config_entry| {
                if (!std.mem.eql(u8, config_entry.key_ptr.*, "origin")) {
                    try config.put(allocator, config_entry.key_ptr.*, config_entry.value_ptr.*);
                }
            }
        }
    }
    try api_zig.database_config.saveDatabaseConfig(allocator, io, log, rawStorage, std.json.Value{
        .object = config,
    });
}

//
// set-database-origin: the payload is {databasePath, origin}, where a missing origin clears it. Writes the origin to the database's
// .db/config.json, and to the database's entry when it has one with a different origin.
//
fn setDatabaseOrigin(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const log = services.log;
    _ = timers;
    _ = context;
    const database_path = json.getString(data, "databasePath") orelse {
        return utils.errors.throwError("The database needs a path.", .{});
    };
    const origin = json.getString(data, "origin");
    const databases = try databases_config.getDatabases(allocator, io);
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const opened = try openDatabaseStorage(allocator, io, databases, database_path, services.nativeCaller(&requester_storage));
    try writeDatabaseOrigin(io, log, allocator, opened.rawStorage, origin);
    if (opened.entry) |found_entry| {
        if (!optionalStringsEqual(found_entry.origin, origin)) {
            var updated_entry = found_entry;
            updated_entry.origin = origin;
            try databases_config.updateDatabaseEntry(allocator, io, found_entry.name, updated_entry);
        }
    }
    log.event(try std.fmt.allocPrint(allocator, "Database origin updated for {s}", .{node_utils.path.basename(database_path)}));
    return try allocator.dupe(u8, "null");
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
fn listS3Dirs(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = timers;
    _ = context;
    const s3_key = json.getString(data, "s3Key") orelse {
        return utils.errors.throwError("The request needs the name of the secret that holds the S3 credentials.", .{});
    };
    const bucket = json.getString(data, "bucket") orelse {
        return utils.errors.throwError("The request needs the name of the S3 bucket.", .{});
    };
    const prefix = json.getString(data, "prefix") orelse {
        return utils.errors.throwError("The request needs the folder to list in the S3 bucket.", .{});
    };
    var requester_storage: ziggy.task_runner.TaskNativeCaller = undefined;
    const vault = try vault_zig.get_vault.getVaultWithHost(allocator, vault_zig.get_vault.getDefaultVaultType(), services.nativeCaller(&requester_storage));
    const secret = try vault.get(allocator, io, s3_key);
    const found_secret = secret orelse {
        return try allocator.dupe(u8, "[]");
    };
    const credentials = try s3CredentialsFromSecret(allocator, found_secret.value);
    var storage = CloudStorage.init(bucket, credentials);
    const path = try storage_zig.storage_factory.pathJoin(allocator, &.{ bucket, prefix });
    const result = try storage.listDirs(allocator, io, path, 100, null);
    return try json.stringify(allocator, result.names);
}

//
// The remove-database-entry message's handler: removeDatabaseEntry, with its errors logged.
//
pub const removeDatabaseEntryHandler = logExceptions(removeDatabaseEntry, "Error removing database entry");

//
// The find-database message's handler: findDatabase, with its errors logged.
//
pub const findDatabaseHandler = logExceptions(findDatabase, "Error finding database");

//
// The get-databases message's handler: getDatabases, with its errors logged.
//
pub const getDatabasesHandler = logExceptions(getDatabases, "Error getting databases");

//
// The add-database message's handler: addDatabase, with its errors logged.
//
pub const addDatabaseHandler = logExceptions(addDatabase, "Error adding database");

//
// The update-database message's handler: updateDatabase, with its errors logged.
//
pub const updateDatabaseHandler = logExceptions(updateDatabase, "Error updating database");

//
// The set-database-origin message's handler: setDatabaseOrigin, with its errors logged.
//
pub const setDatabaseOriginHandler = logExceptions(setDatabaseOrigin, "Error setting database origin");

//
// The list-s3-dirs message's handler: listS3Dirs, with its errors logged.
//
pub const listS3DirsHandler = logExceptions(listS3Dirs, "Error listing S3 directories");

//
// The data of get-databases, which has none.
//
pub const NoRequest = struct {};

//
// remove-database-entry: the data is a database name, answered by the remove-database-entry task. The response is null.
//
pub fn removeDatabaseEntryMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "remove-database-entry",
            .data = try json.stringify(allocator, name),
        },
    };
}

//
// find-database: the data is a database name, answered by the find-database task. The response is the entry, or null.
//
pub fn findDatabaseMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, name: []const u8) !ziggy.core.Response(?IDatabaseEntry) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "find-database",
            .data = try json.stringify(allocator, name),
        },
    };
}

//
// get-databases: answered by the get-databases task. The response is every configured database entry.
//
pub fn getDatabasesMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response([]const IDatabaseEntry) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "get-databases",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of add-database, and the entry of update-database: a database entry as the page sends it.
//
pub const AddDatabaseRequest = struct {
    // The name of the database.
    name: []const u8,
    // What the database is for.
    description: []const u8,
    // Where the database is.
    path: []const u8,
    // The path of the database this one was replicated from, or null.
    origin: ?[]const u8 = null,
    // The name of the vault secret that holds the S3 credentials, or null.
    s3Key: ?[]const u8 = null,
    // The name of the vault secret that holds the encryption key, or null.
    encryptionKey: ?[]const u8 = null,
    // The name of the vault secret that holds the geocoding key, or null.
    geocodingKey: ?[]const u8 = null,
};

//
// add-database: answered by the add-database task, which adds the entry. The response is the entry.
//
pub fn addDatabaseMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: AddDatabaseRequest) !ziggy.core.Response(IDatabaseEntry) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "add-database",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of update-database.
//
pub const UpdateDatabaseRequest = struct {
    // The name of the entry to update.
    originalName: []const u8,
    // The entry to save in its place.
    entry: AddDatabaseRequest,
};

//
// update-database: answered by the update-database task. The response is null.
//
pub fn updateDatabaseMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: UpdateDatabaseRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "update-database",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of set-database-origin.
//
pub const SetDatabaseOriginRequest = struct {
    // The path of the database.
    databasePath: []const u8,
    // The origin to record, or null to clear it.
    origin: ?[]const u8 = null,
};

//
// set-database-origin: answered by the set-database-origin task. The response is null.
//
pub fn setDatabaseOriginMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SetDatabaseOriginRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "set-database-origin",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of list-s3-dirs.
//
pub const ListS3DirsRequest = struct {
    // The name of the vault secret that holds the S3 credentials.
    s3Key: []const u8,
    // The S3 bucket to list.
    bucket: []const u8,
    // The folder in the bucket to list.
    prefix: []const u8,
};

//
// list-s3-dirs: answered by the list-s3-dirs task. The response is the names of the directories under the prefix.
//
pub fn listS3DirsMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: ListS3DirsRequest) !ziggy.core.Response([]const []const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "list-s3-dirs",
            .data = try json.stringify(allocator, request),
        },
    };
}
