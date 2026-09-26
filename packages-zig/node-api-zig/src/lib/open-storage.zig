const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const IStorage = storage_zig.storage.IStorage;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const IEncryptionKeyPem = encryption.key_utils.IEncryptionKeyPem;
const IStorageOptions = encryption.encryption_types.IStorageOptions;
const createStorage = storage_zig.storage_factory.createStorage;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const resolveStorageCredentials = resolve_storage_credentials.resolveStorageCredentials;

//
// Result of opening a database storage instance via openStorage.
// Bundles the constructed storage with the credentials that were used so callers can reuse them
// (e.g. to write an encryption.pub file when the destination is encrypted).
//
pub const IOpenStorageResult = struct {
    //
    // The configured storage instance (transparently decrypts when an encryption key is in use).
    //
    storage: IStorage,

    //
    // The raw underlying storage instance (no encryption layer). Used for reading or writing
    // metadata that must bypass encryption, such as .db/encryption.pub.
    //
    rawStorage: IStorage,

    //
    // The PEM key pairs resolved for this path. Empty when the path is unencrypted.
    //
    encryptionKeyPems: []const IEncryptionKeyPem,

    //
    // The S3 credentials used to construct the storage. Null for non-s3: paths.
    //
    s3Config: ?IS3Credentials,

    //
    // The storage options used to construct the storage. Exposed so callers that need to build
    // a derived storage (e.g. createLazyDatabaseStorage) can reuse them without re-deriving.
    //
    storageOptions: IStorageOptions,

    //
    // The Google geocoding API key, when configured for this path.
    //
    googleApiKey: ?[]const u8,
};

//
// Resolves credentials for the given database path and constructs the storage instance.
// Wraps the standard resolveStorageCredentials + loadEncryptionKeysFromPem + createStorage
// pattern used by every worker handler so the call sites do not duplicate it.
//
// encryptionKey and s3Key are forwarded to resolveStorageCredentials: callers supply them when
// the path is not in databases.json (e.g. the destination of a replicate task) or to override
// the registered values.
// (Zig: the TypeScript optional parameters are passed as null.)
//
pub fn openStorage(
    allocator: std.mem.Allocator,
    io: std.Io,
    databasePath: []const u8,
    encryptionKey: ?[]const u8,
    s3Key: ?[]const u8,
) !IOpenStorageResult {
    const credentials = try resolveStorageCredentials(allocator, io, databasePath, encryptionKey, s3Key);
    const loadedKeys = try loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const storageOptions = loadedKeys.options;
    const created = try createStorage(allocator, io, databasePath, credentials.s3Config, storageOptions);
    return .{
        .storage = created.storage,
        .rawStorage = created.rawStorage,
        .encryptionKeyPems = credentials.encryptionKeyPems,
        .s3Config = credentials.s3Config,
        .storageOptions = storageOptions,
        .googleApiKey = credentials.googleApiKey,
    };
}
