const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const init_cmd = @import("init-cmd.zig");
const createStorage = storage_zig.storage_factory.createStorage;
const ICreateStorageResult = storage_zig.storage_factory.ICreateStorageResult;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const IStorageOptions = encryption.encryption_types.IStorageOptions;
const getDefaultS3Config = init_cmd.getDefaultS3Config;

//
// Returns S3 credentials for paths that require them, or undefined for local paths.
// Vault access only occurs when the path prefix is "s3:".
//
pub fn fetchS3CredentialsForPath(allocator: std.mem.Allocator, io: std.Io, rootPath: []const u8) !?IS3Credentials {
    if (std.mem.startsWith(u8, rootPath, "s3:")) {
        return getDefaultS3Config(allocator, io);
    }

    return null;
}

//
// Creates storage for the given path, fetching S3 credentials from the vault only
// when the path prefix requires them. Local paths never touch the vault.
//
pub fn createStorageForPath(allocator: std.mem.Allocator, io: std.Io, rootPath: []const u8, options: ?IStorageOptions) !ICreateStorageResult {
    const s3Config = try fetchS3CredentialsForPath(allocator, io, rootPath);
    return createStorage(allocator, io, rootPath, s3Config, options);
}
