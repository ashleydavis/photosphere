const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const progress_recorder = @import("progress-recorder.zig");
const verify = node_api.verify;

//
// The id of the asset in test/dbs/v6.
//
const ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// Records progress messages.
//
fn recordProgress(context: ?*anyopaque, _: std.Io, _: ILog, message: ?[]const u8) void {
    const recorder: *progress_recorder.ProgressRecorder = @ptrCast(@alignCast(context.?));
    recorder.record(message orelse "");
}

//
// Runs verify on a database directory.
//
fn runVerify(allocator: std.mem.Allocator, io: std.Io, log: ILog, databaseDir: []const u8, options: ?verify.IVerifyOptions, recorder: ?*progress_recorder.ProgressRecorder) !verify.IVerifyResult {
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const opened = try node_api.open_storage.openStorage(allocator, io, log, databaseDir, null, null, null);
    const database = try node_api.media_file_database.createMediaFileDatabase(allocator, opened.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    const progressCallback: ?node_api.media_file_database.ProgressCallback = if (recorder) |progressRecorder| .{ .context = progressRecorder, .function = recordProgress } else null;
    return verify.verify(allocator, io, log, test_timers.timers(), .{ .databasePath = databaseDir }, opened.storage, uuidGenerator.uuidGenerator(), database.metadataCollection, options, progressCallback);
}

test "verify reports every file of an intact database as unmodified" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    var recorder: progress_recorder.ProgressRecorder = .{ .allocator = allocator };

    const result = try runVerify(allocator, io, log, databaseDir, null, &recorder);

    try std.testing.expectEqual(@as(u64, 1), result.totalImports);
    try std.testing.expectEqual(@as(u64, 4), result.totalFiles);
    try std.testing.expectEqual(@as(u64, 4), result.numUnmodified);
    try std.testing.expectEqual(@as(u64, 0), result.numFailures);
    try std.testing.expectEqual(@as(u64, 4), result.filesProcessed);
    try std.testing.expectEqual(@as(u64, 7), result.nodesProcessed);
    try std.testing.expectEqual(@as(usize, 0), result.modified.len);
    try std.testing.expectEqual(@as(usize, 0), result.removed.len);
    try std.testing.expectEqual(@as(usize, 0), result.new.len);
    try std.testing.expectEqual(@as(usize, 0), result.recordMismatches.?.len);
    try std.testing.expectEqualStrings("Verifying files...", recorder.messages.items[0]);
    try std.testing.expectEqualStrings("Loaded database records... 1 loaded", recorder.messages.items[1]);
    try std.testing.expectEqualStrings("Verified file 4 of 4", recorder.messages.items[recorder.messages.items.len - 1]);
}

test "verify detects removed and modified files" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ databaseDir, "display", ASSET_ID }));
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ databaseDir, "thumb", ASSET_ID }), "modified");

    const result = try runVerify(allocator, io, log, databaseDir, null, null);

    try std.testing.expectEqual(@as(u64, 2), result.numUnmodified);
    try std.testing.expectEqual(@as(usize, 1), result.removed.len);
    try std.testing.expectEqualStrings("display/" ++ ASSET_ID, result.removed[0]);
    try std.testing.expectEqual(@as(usize, 1), result.modified.len);
    try std.testing.expectEqualStrings("thumb/" ++ ASSET_ID, result.modified[0]);
}

test "verify with a path filter only verifies the matching files" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    var recorder: progress_recorder.ProgressRecorder = .{ .allocator = allocator };

    const result = try runVerify(allocator, io, log, databaseDir, .{ .pathFilter = "thumb" }, &recorder);

    try std.testing.expectEqual(@as(u64, 1), result.filesProcessed);
    try std.testing.expectEqual(@as(u64, 7), result.nodesProcessed);
    try std.testing.expectEqualStrings("Verifying files matching: thumb", recorder.messages.items[0]);
}

test "verify reports a long path filter in full" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    var recorder: progress_recorder.ProgressRecorder = .{ .allocator = allocator };
    const longFilter = "thumb/" ++ "x" ** 2000;

    const result = try runVerify(allocator, io, log, databaseDir, .{ .pathFilter = longFilter }, &recorder);

    try std.testing.expectEqual(@as(u64, 0), result.filesProcessed);
    try std.testing.expectEqualStrings("Verifying files matching: " ++ longFilter, recorder.messages.items[0]);
}

test "verify reports a missing database record as a record mismatch" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(allocator, &.{ databaseDir, ".db", "bson", "collections", "metadata", "shards", "96" }));

    const result = try runVerify(allocator, io, log, databaseDir, null, null);

    try std.testing.expectEqual(@as(usize, 1), result.recordMismatches.?.len);
    try std.testing.expectEqualStrings("asset/" ++ ASSET_ID, result.recordMismatches.?[0]);
}

test "verify ignores missing files and records of a partial database" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    const sourceDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    const root = std.fs.path.dirname(sourceDir).?;
    defer temp_dirs.removeTempDir(io, root);
    const partialDir = try std.fs.path.join(allocator, &.{ root, "partial" });
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    _ = try node_api.replicate_database.replicateDatabase(allocator, io, log, test_timers.timers(), uuidGenerator.uuidGenerator(), .{ .sourcePath = sourceDir, .destPath = partialDir, .partial = true, .force = false }, null);

    const result = try runVerify(allocator, io, log, partialDir, null, null);

    try std.testing.expectEqual(@as(u64, 4), result.numUnmodified);
    try std.testing.expectEqual(@as(usize, 0), result.removed.len);
    try std.testing.expectEqual(@as(usize, 0), result.recordMismatches.?.len);
}

test "verifyDatabaseFiles verifies the trees, shards and sort indexes" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);
    var recorder: progress_recorder.ProgressRecorder = .{ .allocator = allocator };

    const result = try verify.verifyDatabaseFiles(allocator, io, log, storage, .{ .context = &recorder, .function = recordProgress });

    try std.testing.expectEqual(@as(u64, 8), result.totalFiles);
    try std.testing.expectEqual(@as(u64, 8), result.validFiles);
    try std.testing.expectEqual(@as(usize, 0), result.invalidFiles.len);
    try std.testing.expect(result.totalSize > 0);
    try std.testing.expectEqualStrings("Verifying database files...", recorder.messages.items[0]);
    try std.testing.expectEqualStrings("Verified database file 8 of 8", recorder.messages.items[8]);
}

test "verifyDatabaseFiles reports a corrupted shard" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const shardPath = try std.fs.path.join(allocator, &.{ databaseDir, ".db", "bson", "collections", "metadata", "shards", "96" });
    const shard = try test_files.readFile(allocator, io, shardPath);
    shard[shard.len / 2] ^= 0xff;
    try test_files.writeFile(io, shardPath, shard);
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);

    const result = try verify.verifyDatabaseFiles(allocator, io, log, storage, null);

    try std.testing.expectEqual(@as(u64, 7), result.validFiles);
    try std.testing.expectEqual(@as(usize, 1), result.invalidFiles.len);
    try std.testing.expectEqualStrings(".db/bson/collections/metadata/shards/96", result.invalidFiles[0]);
    try std.testing.expect(std.mem.startsWith(u8, result.errors[0].@"error", "Checksum mismatch: expected "));
}

test "verifyDatabaseFiles reports every kind of database file that is corrupted, and skips build checkpoints" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    // The database tree, a shard's tree and a sort index's tree have a byte flipped; the collection tree is too short
    // to be one.
    const flipped = [_][]const u8{ ".db/files.dat", ".db/bson/collections/metadata/shards/96.dat", ".db/bson/indexes/metadata/hash_asc/tree.dat" };
    for (flipped) |relativePath| {
        const filePath = try std.fs.path.join(allocator, &.{ databaseDir, relativePath });
        const contents = try test_files.readFile(allocator, io, filePath);
        contents[contents.len / 2] ^= 0xff;
        try test_files.writeFile(io, filePath, contents);
    }
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ databaseDir, ".db", "bson", "collections", "metadata", "collection.dat" }), "short");
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ databaseDir, ".db", "bson", "indexes", "metadata", "hash_asc", "build.checkpoint" }), "not a serialized file");
    const storage = try test_files.directoryStorage(allocator, io, databaseDir);

    const result = try verify.verifyDatabaseFiles(allocator, io, log, storage, null);

    try std.testing.expectEqual(@as(u64, 4), result.validFiles);
    try std.testing.expectEqual(@as(usize, 4), result.invalidFiles.len);
    for (result.invalidFiles) |invalidFile| {
        try std.testing.expect(!std.mem.endsWith(u8, invalidFile, "build.checkpoint"));
    }
    var sawTooSmall = false;
    for (result.errors) |fileError| {
        if (std.mem.eql(u8, fileError.file, ".db/bson/collections/metadata/collection.dat")) {
            try std.testing.expect(std.mem.startsWith(u8, fileError.@"error", "File too small for v6 format (5 bytes"));
            sawTooSmall = true;
        }
    }
    try std.testing.expect(sawTooSmall);
}

test "verify reports a database record whose hash is wrong as a record mismatch" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "v6");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const test_env = try test_environment.setupEnvironmentWith(io, allocator);
    defer test_env.deinitWith(log, allocator);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    const opened = try node_api.open_storage.openStorage(allocator, io, log, databaseDir, null, null, null);
    const database = try node_api.media_file_database.createMediaFileDatabase(allocator, opened.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    var updates: @import("serialization-zig").bson.BsonDocument = .empty;
    try updates.put(allocator, "hash", .{ .string = "0000" });
    try std.testing.expect(try database.metadataCollection.updateOne(io, log, ASSET_ID, updates, .{}));
    try database.bsonDatabase.commit(io, log);

    const result = try runVerify(allocator, io, log, databaseDir, null, null);

    try std.testing.expectEqual(@as(usize, 1), result.recordMismatches.?.len);
    try std.testing.expectEqualStrings("asset/" ++ ASSET_ID, result.recordMismatches.?[0]);
}

test "verify fails for a directory that holds no database" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironmentWith(std.testing.io, allocator);
    defer test_env.deinitWith(log, allocator);
    const io = std.testing.io;
    const emptyDir = try temp_dirs.makeTempDir(allocator, io, "verify-no-database");
    defer temp_dirs.removeTempDir(io, emptyDir);

    try std.testing.expectError(error.Thrown, runVerify(allocator, io, log, emptyDir, null, null));
    try std.testing.expectEqualStrings("Failed to load merkle tree", utils.errors.lastErrorMessage());
}
