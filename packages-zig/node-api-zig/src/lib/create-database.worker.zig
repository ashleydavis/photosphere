const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const task_queue_zig = @import("ziggy-core").task_queue;
const media_file_database = @import("media-file-database.zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const createStorage = storage_zig.storage_factory.createStorage;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const createDatabase = media_file_database.createDatabase;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const resolveStorageCredentials = resolve_storage_credentials.resolveStorageCredentials;

//
// Input data for the create-database task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const ICreateDatabaseData = struct {
    //
    // Filesystem path of the directory in which to create the new database.
    //
    databasePath: []const u8 = "",
};

//
// Task handler that initializes a new empty media file database at the given path.
// (Zig: the task data is a JSON value holding ICreateDatabaseData, and the task returns no value, so the handler returns
// JSON null.)
//
pub fn createDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when databasePath is not a string.
    // The failure is reported as a sentence, not a bare parser
    // error name.)
    const data = std.json.parseFromValueLeaky(ICreateDatabaseData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The create-database task data is not valid: databasePath must be a string", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const credentials = try resolveStorageCredentials(allocator, io, data.databasePath, null, null, context.hostRequester);
    const loadedKeys = try loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const created = try createStorage(allocator, io, data.databasePath, credentials.s3Config, loadedKeys.options);
    const database = try createMediaFileDatabase(allocator, created.storage, context.uuidGenerator, context.timestampProvider);
    try createDatabase(allocator, io, created.storage, created.rawStorage, context.uuidGenerator, database.metadataCollection, null);
    return .null;
}
