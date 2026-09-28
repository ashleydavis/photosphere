//
// Port of apps/cli/src/cmd/hash.ts: computes the hash of a file using the same algorithm as the database.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const log = &utils.log.log;
const path = node_utils.path;
const Date = utils.timestamp_provider.Date;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const computeHash = node_api.hash.computeHash;
const exit = node_utils.termination.exit;
const resolveKeyPems = init_cmd.resolveKeyPems;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const createStorageForPath = storage_helper.createStorageForPath;

//
// Options of the hash command (TypeScript: IHashCommandOptions).
//
pub const IHashCommandOptions = struct {
    // Enables verbose logging.
    verbose: ?bool = null,

    // Non-interactive mode: use defaults and command line arguments.
    yes: ?bool = null,

    // The encryption key file(s) used to read the file, comma-separated.
    key: ?[]const u8 = null,
};

//
// Compute the hash of a file.
//
pub fn hashCommand(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, options: *const IHashCommandOptions) !void {
    if (filePath.len == 0) {
        log.@"error"(try pc.red(allocator, "File path is required."));
        exit(io, 1);
    }

    if (std.mem.startsWith(u8, filePath, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, options.yes orelse false);
    }

    const keyPems = try resolveKeyPems(allocator, io, options.key);
    const storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;

    const dirPath = path.dirname(filePath);
    const fileName = path.basename(filePath);
    const created = try createStorageForPath(allocator, io, dirPath, storageOptions);
    const storage = created.storage;

    if (options.verbose orelse false) {
        log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "Storage type: {s}", .{created.type})));
        log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "Path for storage operations: {s}", .{created.normalizedPath})));
    }

    const fileInfo = try storage.info(allocator, io, fileName) orelse {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "File not found: {s}", .{filePath})));
        exit(io, 1);
    };

    const stream = try storage.readStream(allocator, io, fileName);
    defer stream.destroy(io);
    const hashBuffer = try computeHash(stream.reader());
    const hashHex = std.fmt.bytesToHex(hashBuffer, .lower);

    // Print results
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "File: {s}", .{filePath})));
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Hash: {s}", .{&hashHex})));
    const isoDate = try allocator.dupe(u8, try (Date{ .epochMilliseconds = fileInfo.lastModified }).toISOString(allocator));
    std.mem.replaceScalar(u8, isoDate, 'T', ' ');
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Date: {s}", .{isoDate[0..19]})));
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Size: {d} bytes", .{fileInfo.length})));
}
