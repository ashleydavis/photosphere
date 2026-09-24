const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const storage_module = @import("storage.zig");
const file_storage = @import("file-storage.zig");
const cloud_storage = @import("cloud-storage.zig");
const encrypted_storage = @import("encrypted-storage.zig");
const storage_prefix_wrapper = @import("storage-prefix-wrapper.zig");

const errors = utils.errors;
const IStorage = storage_module.IStorage;
const FileStorage = file_storage.FileStorage;
const CloudStorage = cloud_storage.CloudStorage;
const IS3Credentials = cloud_storage.IS3Credentials;
const EncryptedStorage = encrypted_storage.EncryptedStorage;
const StoragePrefixWrapper = storage_prefix_wrapper.StoragePrefixWrapper;
const IStorageOptions = encryption.encryption_types.IStorageOptions;

//
// Join paths.
// (Zig: the paths are passed as a slice, `pathJoin(allocator, &.{ a, b })`.)
//
pub fn pathJoin(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    var first = true;
    for (paths) |path| {
        if (path.len == 0) {
            continue;
        }
        if (!first) {
            try joined.append(allocator, '/');
        }
        try joined.appendSlice(allocator, path);
        first = false;
    }

    // Remove trailing slashes (TypeScript: `.replace(/\/+$/, '')`).
    var length = joined.items.len;
    while (length > 0 and joined.items[length - 1] == '/') {
        length -= 1;
    }

    // Filter out double forward slashes.
    var result: std.ArrayList(u8) = .empty;
    for (joined.items[0..length]) |character| {
        if (character == '/' and result.items.len > 0 and result.items[result.items.len - 1] == '/') {
            continue;
        }
        try result.append(allocator, character);
    }

    return result.toOwnedSlice(allocator);
}

//
// Result of creating a storage instance.
//
pub const ICreateStorageResult = struct {
    //
    // The storage instance, wrapped with encryption if keys were provided.
    //
    storage: IStorage,

    //
    // The raw (unencrypted) storage instance, for writing files that must be readable without a key.
    //
    rawStorage: IStorage,

    //
    // The normalized path used as the storage root prefix.
    //
    normalizedPath: []const u8,

    //
    // The storage type identifier (e.g. "fs", "s3", "encrypted-fs").
    //
    @"type": []const u8,
};

//
// Resolves a path to an absolute path like Node's `path.resolve(path)` (relative paths resolve against the cwd).
//
fn resolvePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    return std.fs.path.resolve(allocator, &.{ currentPath, path });
}

//
// Creates the appropriate storage implementation based on the prefix in the path.
// (Zig: the storage objects are allocated with the allocator and live as long as its memory.)
//
pub fn createStorage(allocator: std.mem.Allocator, io: std.Io, rootPath: []const u8, s3Config: ?IS3Credentials, options: ?IStorageOptions) !ICreateStorageResult {
    if (rootPath.len == 0) {
        return errors.throwError("Path is required", .{});
    }

    var storage: IStorage = undefined;
    var normalizedPath: []const u8 = undefined;
    var storageType: []const u8 = undefined;

    // Check for storage prefix
    if (std.mem.startsWith(u8, rootPath, "fs:")) {
        const fileStorage = try allocator.create(FileStorage);
        fileStorage.* = FileStorage.init("fs:");
        storage = fileStorage.storage();
        normalizedPath = try resolvePath(allocator, io, rootPath["fs:".len..]);
        storageType = "fs";
    }
    else if (std.mem.startsWith(u8, rootPath, "s3:")) {
        // For S3, we keep the bucket:key format that CloudStorage expects
        const s3Path = rootPath["s3:".len..];
        const cloudStorage = try allocator.create(CloudStorage);
        cloudStorage.* = CloudStorage.init(io, "s3:", s3Config);
        storage = cloudStorage.storage();
        normalizedPath = s3Path;
        storageType = "s3";
    }
    else {
        // Assume local file system for backward compatibility
        const fileStorage = try allocator.create(FileStorage);
        fileStorage.* = FileStorage.init("fs:");
        storage = fileStorage.storage();
        normalizedPath = try resolvePath(allocator, io, rootPath);
        storageType = "fs";
    }

    // Convert backslashes to forward slashes for consistency.
    const forwardSlashPath = try allocator.dupe(u8, normalizedPath);
    std.mem.replaceScalar(u8, forwardSlashPath, '\\', '/');
    normalizedPath = forwardSlashPath;

    const rawStorage = try allocator.create(StoragePrefixWrapper);
    rawStorage.* = try StoragePrefixWrapper.init(allocator, storage, normalizedPath);

    // Wrap with encryption if keys are provided
    if (options) |storageOptions| {
        if (storageOptions.decryptionKeyMap != null and storageOptions.encryptionPublicKey != null) {
            const encryptedStorage = try allocator.create(EncryptedStorage);
            encryptedStorage.* = EncryptedStorage.init(storage.location, storage, storageOptions.decryptionKeyMap.?, storageOptions.encryptionPublicKey.?);
            storage = encryptedStorage.storage();
            storageType = try std.fmt.allocPrint(allocator, "encrypted-{s}", .{storageType});
        }
    }

    const prefixedStorage = try allocator.create(StoragePrefixWrapper);
    prefixedStorage.* = try StoragePrefixWrapper.init(allocator, storage, normalizedPath);

    return .{
        .storage = prefixedStorage.storage(),
        .rawStorage = rawStorage.storage(),
        .normalizedPath = normalizedPath,
        .@"type" = storageType,
    };
}
