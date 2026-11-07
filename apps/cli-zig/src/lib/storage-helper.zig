const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const init_cmd = @import("init-cmd.zig");
const directory_picker = @import("directory-picker.zig");
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
// Creates storage for the given path, fetching S3 credentials from the vault only for an `s3:` path. A relative path is resolved
// against the working directory, which the empty base directory names.
//
pub fn createStorageForPath(allocator: std.mem.Allocator, io: std.Io, rootPath: []const u8, options: ?IStorageOptions) !ICreateStorageResult {
    const s3Config = try fetchS3CredentialsForPath(allocator, io, rootPath);
    return createStorage(allocator, io, "", rootPath, s3Config, options);
}

//
// The path the CLI opens for a database path given with --db, once a database record has not matched it. A path that is not a
// simple name (an absolute or `s3:` path, `.`, or a relative path with more than one segment) is used as it is, so a relative one
// means the working directory. A simple name that names a database in the working directory is used as it is. Otherwise, when the
// `dbs` directory of the desktop app's data directory (or of the one PHOTOSPHERE_DATA_DIR names) holds a database of that name, the
// database there is opened, so the CLI finds a database of the desktop app by the name the app knows it by. Failing both, the name
// is used as it is, in the working directory, which is where a new database is made. The data directory is worked out only when the
// working directory holds no database of the name.
//
pub fn resolveDatabasePath(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8) ![]const u8 {
    if (!node_api.database_base_dir.isSimpleName(databasePath)) {
        return databasePath;
    }
    const name = if (std.mem.startsWith(u8, databasePath, "fs:")) databasePath["fs:".len..] else databasePath;
    if (try directory_picker.isMediaDatabase(allocator, io, name)) {
        return databasePath;
    }
    const databasesDir = try node_api.database_base_dir.databaseBaseDir(allocator, try node_api.desktop_data_dir.commandLineDataDir(allocator));
    if (databasesDir.len > 0) {
        const inDatabasesDir = try std.fs.path.join(allocator, &.{ databasesDir, name });
        if (try directory_picker.isMediaDatabase(allocator, io, inDatabasesDir)) {
            return inDatabasesDir;
        }
    }
    return databasePath;
}

//
// The --db value every command is given, resolved once when the command line is parsed (see resolveDatabasePath). A value that a
// database record in databases.toml has as its path or its name is left as it is, so each command can still look the record up by it.
//
pub fn resolveDatabaseOption(allocator: std.mem.Allocator, io: std.Io, databaseOption: []const u8) ![]const u8 {
    const databases = try node_api.databases_config.getDatabases(allocator, io);
    for (databases) |databaseRecord| {
        if (std.mem.eql(u8, databaseRecord.path, databaseOption) or node_api.databases_config.namesMatch(databaseRecord.name, databaseOption)) {
            return databaseOption;
        }
    }
    return resolveDatabasePath(allocator, io, databaseOption);
}
