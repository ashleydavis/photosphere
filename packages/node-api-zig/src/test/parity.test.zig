const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const TaskContext = task_queue_zig.task_context.TaskContext;
const api = @import("api-zig");
const IReplicateDatabaseData = api.replicate_database_types.IReplicateDatabaseData;

//
// End to end parity tests: the Zig port and the TypeScript node-api (run with bun) replicate and verify the same
// databases, and everything they write and report must be identical. The only allowed differences are values
// that are time based in TypeScript too: the leaf timestamps inside the merkle tree files (compared after both
// sides load the trees, zero the timestamps and save them again with their own implementation), lastReplicatedAt
// in .db/state.dat (compared after loading it), and the random IVs of encrypted files (compared after decryption).
//

//
// The id of the asset in test/dbs/v6.
//
const V6_ASSET_ID = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// The TypeScript generated key used for encrypted databases.
//
const KEY_FILE = helpers.KEYS_DIR ++ "/ts-private.pem";

//
// Ignores task messages.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// The directories of a parity scenario.
//
const Scenario = struct {
    // The directory holding everything.
    root: []const u8,

    // The source database (a copy of a test database).
    source: []const u8,

    // The replica written by Zig.
    zigReplica: []const u8,

    // The replica written by TypeScript.
    tsReplica: []const u8,

    // The uuid counter directory (TEST_TMP_DIR) of the Zig side.
    zigCounter: []const u8,

    // The uuid counter directory (TEST_TMP_DIR) of the TypeScript side.
    tsCounter: []const u8,
};

//
// Creates a scenario for a copy of test/dbs/<name>.
//
fn makeScenario(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !Scenario {
    _ = try helpers.setupEnvironment(io);
    try node_api.task_handlers.initTaskHandlers();
    const source = try helpers.copyTestDatabase(allocator, io, name);
    const root = std.fs.path.dirname(source).?;
    return .{
        .root = root,
        .source = source,
        .zigReplica = try std.fmt.allocPrint(allocator, "{s}/zig-replica", .{root}),
        .tsReplica = try std.fmt.allocPrint(allocator, "{s}/ts-replica", .{root}),
        .zigCounter = try std.fmt.allocPrint(allocator, "{s}/zig-counter", .{root}),
        .tsCounter = try std.fmt.allocPrint(allocator, "{s}/ts-counter", .{root}),
    };
}

//
// Replicates with the Zig replicate-database handler (TestUuidGenerator counting in counterDir).
//
fn zigReplicate(allocator: std.mem.Allocator, io: std.Io, counterDir: []const u8, data: IReplicateDatabaseData) ![]const u8 {
    try helpers.setEnv("TEST_TMP_DIR", counterDir);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: utils.timestamp_provider.TimestampProvider = .{};
    var context = TaskContext.init(uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider(), "parity", "parity-task", .{ .context = null, .function = ignoreMessage }, 10);
    const output = try node_api.replicate_database_worker.replicateDatabaseHandler(allocator, io, try node_api.replicate_database.replicateDatabaseDataToJson(allocator, data), context.taskContext());
    return std.json.Stringify.valueAlloc(allocator, output, .{});
}

//
// Replicates with the TypeScript replicate-database handler (TestUuidGenerator counting in counterDir).
//
fn tsReplicate(allocator: std.mem.Allocator, io: std.Io, counterDir: []const u8, data: IReplicateDatabaseData) ![]const u8 {
    const mode = if (data.partial) "partial" else "full";
    const output = try helpers.runBunJson(allocator, io, "replicate-ts.ts", &.{ data.sourcePath, data.destPath, mode, data.destEncryptionKey orelse "", data.sourceEncryptionKey orelse "", data.pathFilter orelse "" }, &.{.{ "TEST_TMP_DIR", counterDir }});
    return std.json.Stringify.valueAlloc(allocator, output, .{});
}

//
// Replicates with both implementations and checks that the results and the replicas are identical.
//
fn replicateBoth(allocator: std.mem.Allocator, io: std.Io, scenario: Scenario, partial: bool, destKey: ?[]const u8, sourceKey: ?[]const u8) ![]const u8 {
    const zigResult = try zigReplicate(allocator, io, scenario.zigCounter, .{ .sourcePath = scenario.source, .destPath = scenario.zigReplica, .partial = partial, .force = false, .destEncryptionKey = destKey, .sourceEncryptionKey = sourceKey });
    const tsResult = try tsReplicate(allocator, io, scenario.tsCounter, .{ .sourcePath = scenario.source, .destPath = scenario.tsReplica, .partial = partial, .force = false, .destEncryptionKey = destKey, .sourceEncryptionKey = sourceKey });
    try std.testing.expectEqualStrings(tsResult, zigResult);
    try compareReplicas(allocator, io, scenario.zigReplica, scenario.tsReplica, destKey);
    return zigResult;
}

//
// Lists the files of a directory tree (relative paths, sorted).
//
fn listFiles(allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, dirPath, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) {
            try files.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }
    helpers.sortStrings(files.items);
    return files.items;
}

//
// Gets the type code of a merkle tree file, or null when the file is not a merkle tree (as normalize-trees.ts).
//
fn treeTypeCode(fileName: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, fileName, ".db/files.dat")) {
        return "FTRE";
    }
    if (std.mem.eql(u8, fileName, ".db/bson/db.dat")) {
        return "BDBT";
    }
    if (std.mem.startsWith(u8, fileName, ".db/bson/collections/") and std.mem.endsWith(u8, fileName, ".dat")) {
        return "COLT";
    }
    return null;
}

//
// Loads every merkle tree of a database with the Zig port, zeroes the leaf timestamps and saves the trees with the
// Zig port under the same paths in outputDir (the Zig half of normalize-trees.ts).
//
fn zigNormalizeTrees(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8, outputDir: []const u8, key: ?[]const u8) !void {
    const opened = try node_api.open_storage.openStorage(allocator, io, databaseDir, key, null);
    const outputStorage = try helpers.directoryStorage(allocator, io, outputDir);
    for (try listFiles(allocator, io, databaseDir)) |fileName| {
        const typeCode = treeTypeCode(fileName) orelse {
            continue;
        };
        var tree = (try merkle_tree.loadTree(allocator, io, fileName, opened.storage, typeCode)).?;
        var nodes = merkle_tree.iterateLeaves(merkle_tree.SortNode, allocator, tree.sort);
        while (try nodes.next()) |node| {
            if (node.lastModified != null) {
                node.lastModified = 0;
            }
        }
        try merkle_tree.saveTree(allocator, io, fileName, &tree, outputStorage, typeCode);
    }
}

//
// Checks that two database state files hold the same state, apart from the time of the replication
// (lastReplicatedAt is present in both, and its value is the time each replication ran).
//
fn sameDatabaseState(allocator: std.mem.Allocator, io: std.Io, zigDir: []const u8, tsDir: []const u8) !bool {
    const zigState = (try api.database_state.loadDatabaseState(allocator, io, try helpers.directoryStorage(allocator, io, zigDir))).?;
    const tsState = (try api.database_state.loadDatabaseState(allocator, io, try helpers.directoryStorage(allocator, io, tsDir))).?;
    if (zigState.lastReplicatedAt == null or tsState.lastReplicatedAt == null) {
        return false;
    }
    if (zigState.contentHash == null or tsState.contentHash == null) {
        return zigState.contentHash == null and tsState.contentHash == null;
    }
    return std.mem.eql(u8, zigState.contentHash.?, tsState.contentHash.?) and
        (zigState.lastModifiedAt == null) == (tsState.lastModifiedAt == null) and
        (zigState.lastSyncedAt == null) == (tsState.lastSyncedAt == null);
}

//
// Checks that two replicas hold the same files with the same bytes (see the file comment for the exceptions).
//
fn compareReplicas(allocator: std.mem.Allocator, io: std.Io, zigDir: []const u8, tsDir: []const u8, key: ?[]const u8) !void {
    const zigFiles = try listFiles(allocator, io, zigDir);
    const tsFiles = try listFiles(allocator, io, tsDir);
    if (zigFiles.len != tsFiles.len) {
        std.debug.print("Zig replica files: {f}\nTypeScript replica files: {f}\n", .{ std.json.fmt(zigFiles, .{}), std.json.fmt(tsFiles, .{}) });
    }
    try std.testing.expectEqual(tsFiles.len, zigFiles.len);
    for (zigFiles, tsFiles) |zigFile, tsFile| {
        try std.testing.expectEqualStrings(tsFile, zigFile);
    }

    // The trees, loaded and saved again by each implementation with the timestamps zeroed.
    const zigNormalized = try std.fmt.allocPrint(allocator, "{s}-normalized", .{zigDir});
    const tsNormalized = try std.fmt.allocPrint(allocator, "{s}-normalized", .{tsDir});
    std.Io.Dir.cwd().deleteTree(io, zigNormalized) catch {};
    std.Io.Dir.cwd().deleteTree(io, tsNormalized) catch {};
    try zigNormalizeTrees(allocator, io, zigDir, zigNormalized, key);
    _ = try helpers.runBun(allocator, io, "normalize-trees.ts", &.{ tsDir, tsNormalized, key orelse "" }, &.{});

    const zigStorage = (try node_api.open_storage.openStorage(allocator, io, zigDir, key, null)).storage;
    const tsStorage = (try node_api.open_storage.openStorage(allocator, io, tsDir, key, null)).storage;
    var differences: std.ArrayList([]const u8) = .empty;
    for (zigFiles) |fileName| {
        const zigBytes = try helpers.readFile(allocator, io, try std.fs.path.join(allocator, &.{ zigDir, fileName }));
        const tsBytes = try helpers.readFile(allocator, io, try std.fs.path.join(allocator, &.{ tsDir, fileName }));
        if (treeTypeCode(fileName) != null) {
            const zigTree = try helpers.readFile(allocator, io, try std.fs.path.join(allocator, &.{ zigNormalized, fileName }));
            const tsTree = try helpers.readFile(allocator, io, try std.fs.path.join(allocator, &.{ tsNormalized, fileName }));
            if (!std.mem.eql(u8, zigTree, tsTree)) {
                try differences.append(allocator, fileName);
            }
            continue;
        }
        if (std.mem.eql(u8, fileName, ".db/state.dat")) {
            if (!try sameDatabaseState(allocator, io, zigDir, tsDir)) {
                try differences.append(allocator, fileName);
            }
            continue;
        }
        if (std.mem.eql(u8, zigBytes, tsBytes)) {
            continue;
        }
        if (key != null) {
            // Encrypted files differ in their random IVs: compare the decrypted contents.
            const zigPlain = (try zigStorage.read(allocator, io, fileName)).?;
            const tsPlain = (try tsStorage.read(allocator, io, fileName)).?;
            if (std.mem.eql(u8, zigPlain, tsPlain)) {
                continue;
            }
        }
        try differences.append(allocator, fileName);
    }
    if (differences.items.len > 0) {
        std.debug.print("Files that differ between the Zig replica {s} and the TypeScript replica {s}: {f}\n", .{ zigDir, tsDir, std.json.fmt(differences.items, .{}) });
    }
    try std.testing.expectEqual(@as(usize, 0), differences.items.len);
}

//
// Reads a database with the TypeScript node-api (inspect-db.ts).
//
fn tsInspect(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8, key: ?[]const u8) !std.json.Value {
    return helpers.runBunJson(allocator, io, "inspect-db.ts", &.{ databaseDir, key orelse "" }, &.{});
}

//
// Stringifies a JSON value.
//
fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

//
// Verifies a database with the Zig port (verify and verifyDatabaseFiles, as psi verify does) and checks that the
// results equal what the TypeScript verify reports for the same database.
//
fn expectVerifyMatchesTypeScript(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8, key: ?[]const u8, inspected: std.json.Value) !void {
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: utils.timestamp_provider.TimestampProvider = .{};
    const opened = try node_api.open_storage.openStorage(allocator, io, databaseDir, key, null);
    const database = try node_api.media_file_database.createMediaFileDatabase(allocator, opened.storage, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
    var result = try node_api.verify.verify(allocator, io, .{ .databasePath = databaseDir, .encryptionKey = key }, opened.storage, uuidGenerator.uuidGenerator(), database.metadataCollection, .{}, null);
    const modified = try allocator.dupe([]const u8, result.modified);
    helpers.sortStrings(modified);
    result.modified = modified;
    const removed = try allocator.dupe([]const u8, result.removed);
    helpers.sortStrings(removed);
    result.removed = removed;
    const recordMismatches = try allocator.dupe([]const u8, result.recordMismatches.?);
    helpers.sortStrings(recordMismatches);
    result.recordMismatches = recordMismatches;
    try std.testing.expectEqualStrings(try stringify(allocator, inspected.object.get("verify").?), try stringify(allocator, result));

    const databaseFiles = try node_api.verify.verifyDatabaseFiles(allocator, io, opened.storage, null);
    try std.testing.expectEqualStrings(try stringify(allocator, inspected.object.get("databaseFiles").?), try stringify(allocator, databaseFiles));
}

//
// Checks that a replica reads, in TypeScript, like its source: same summary (files root hash, counts, sizes),
// database id and metadata (plus isPartial, true for a partial replica and false for a full one), and that the Zig and TypeScript verify agree.
//
fn expectReplicaMatchesSource(allocator: std.mem.Allocator, io: std.Io, sourceDir: []const u8, replicaDir: []const u8, sourceKey: ?[]const u8, replicaKey: ?[]const u8, partial: bool) !void {
    const source = try tsInspect(allocator, io, sourceDir, sourceKey);
    const replica = try tsInspect(allocator, io, replicaDir, replicaKey);
    var sourceSummary = source.object.get("summary").?;
    var replicaSummary = replica.object.get("summary").?;
    if (sourceKey != null or replicaKey != null) {
        // TypeScript quirk kept by the port: the files tree of an encrypted database records the on-disk
        // (encrypted) length of each copied file, so totalSize differs between a plain and an encrypted copy.
        _ = sourceSummary.object.orderedRemove("totalSize");
        _ = replicaSummary.object.orderedRemove("totalSize");
    }
    // TypeScript behaviour kept by the port: replicating test/dbs/50-assets gives the replica's BSON database a
    // different root hash from its source's (psi summary of a TypeScript replica shows the same). The BSON files
    // of the Zig and TypeScript replicas are compared byte for byte by compareReplicas.
    _ = sourceSummary.object.orderedRemove("databaseHash");
    _ = replicaSummary.object.orderedRemove("databaseHash");
    _ = sourceSummary.object.orderedRemove("fullHash");
    _ = replicaSummary.object.orderedRemove("fullHash");
    if (partial) {
        try sourceSummary.object.put(allocator, "mode", .{ .string = "partial" });
    }
    try std.testing.expectEqualStrings(try stringify(allocator, sourceSummary), try stringify(allocator, replicaSummary));
    try std.testing.expectEqualStrings(source.object.get("databaseId").?.string, replica.object.get("databaseId").?.string);
    var expectedMetadata = source.object.get("databaseMetadata").?;
    try expectedMetadata.object.put(allocator, "isPartial", .{ .bool = partial });
    try std.testing.expectEqualStrings(try stringify(allocator, expectedMetadata), try stringify(allocator, replica.object.get("databaseMetadata").?));
    try expectVerifyMatchesTypeScript(allocator, io, replicaDir, replicaKey, replica);
}

test "full replication of v6 writes the same replica as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "v6");
    defer helpers.removeTempDir(io, scenario.root);

    const result = try replicateBoth(allocator, io, scenario, false, null, null);
    try std.testing.expectEqualStrings("{\"filesImported\":1,\"copiedFiles\":3,\"copiedRecords\":1,\"prunedFiles\":[],\"missingFromSource\":[]}", result);
    try expectReplicaMatchesSource(allocator, io, scenario.source, scenario.zigReplica, null, null, false);
}

test "full replication of 50-assets writes the same replica as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "50-assets");
    defer helpers.removeTempDir(io, scenario.root);

    _ = try replicateBoth(allocator, io, scenario, false, null, null);
    try expectReplicaMatchesSource(allocator, io, scenario.source, scenario.zigReplica, null, null, false);
}

test "partial replication writes the same replica as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "50-assets");
    defer helpers.removeTempDir(io, scenario.root);

    _ = try replicateBoth(allocator, io, scenario, true, null, null);
    try expectReplicaMatchesSource(allocator, io, scenario.source, scenario.zigReplica, null, null, true);
}

test "replicating again copies nothing, then carries over an edited record and a removed asset like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "v6");
    defer helpers.removeTempDir(io, scenario.root);

    _ = try replicateBoth(allocator, io, scenario, false, null, null);

    // No changes.
    const unchanged = try replicateBoth(allocator, io, scenario, false, null, null);
    try std.testing.expectEqualStrings("{\"filesImported\":1,\"copiedFiles\":0,\"copiedRecords\":0,\"prunedFiles\":[],\"missingFromSource\":[]}", unchanged);

    // A record edited by TypeScript.
    _ = try helpers.runBun(allocator, io, "modify-db.ts", &.{ scenario.source, "edit", V6_ASSET_ID }, &.{.{ "TEST_TMP_DIR", scenario.root }});
    const edited = try replicateBoth(allocator, io, scenario, false, null, null);
    try std.testing.expectEqualStrings("{\"filesImported\":1,\"copiedFiles\":0,\"copiedRecords\":2,\"prunedFiles\":[],\"missingFromSource\":[]}", edited);

    // TypeScript quirk kept by the port: the edited record differs in both directions, so replicateBsonDatabase
    // copies it and then deletes it (copiedRecords is 2 and the replica loses the record). Both replicas read alike.
    var zigInspected = try tsInspect(allocator, io, scenario.zigReplica, null);
    var tsInspected = try tsInspect(allocator, io, scenario.tsReplica, null);
    // The compressed size of the tree files depends on the timestamps they hold (compared after zeroing above).
    _ = zigInspected.object.getPtr("databaseFiles").?.object.orderedRemove("totalSize");
    _ = tsInspected.object.getPtr("databaseFiles").?.object.orderedRemove("totalSize");
    try std.testing.expectEqualStrings(try stringify(allocator, tsInspected), try stringify(allocator, zigInspected));
    try std.testing.expect(zigInspected.object.get("summary").?.object.get("databaseHash") == null);
    try expectVerifyMatchesTypeScript(allocator, io, scenario.zigReplica, null, try tsInspect(allocator, io, scenario.zigReplica, null));

    // An asset removed by TypeScript.
    _ = try helpers.runBun(allocator, io, "modify-db.ts", &.{ scenario.source, "remove", V6_ASSET_ID }, &.{.{ "TEST_TMP_DIR", scenario.root }});
    const removed = try replicateBoth(allocator, io, scenario, false, null, null);
    const parsedRemoved = try std.json.parseFromSliceLeaky(std.json.Value, allocator, removed, .{});
    try std.testing.expectEqual(@as(usize, 3), parsedRemoved.object.get("prunedFiles").?.array.items.len);
    try expectReplicaMatchesSource(allocator, io, scenario.source, scenario.zigReplica, null, null, false);
}

test "verify reports the same results as TypeScript for intact, file-deleted, file-modified and partial databases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "50-assets");
    defer helpers.removeTempDir(io, scenario.root);

    // Intact.
    try expectVerifyMatchesTypeScript(allocator, io, scenario.source, null, try tsInspect(allocator, io, scenario.source, null));

    // Partial.
    _ = try zigReplicate(allocator, io, scenario.zigCounter, .{ .sourcePath = scenario.source, .destPath = scenario.zigReplica, .partial = true, .force = false });
    try expectVerifyMatchesTypeScript(allocator, io, scenario.zigReplica, null, try tsInspect(allocator, io, scenario.zigReplica, null));

    // Files deleted and modified, a record deleted and a shard corrupted.
    const assets = try listFiles(allocator, io, try std.fmt.allocPrint(allocator, "{s}/asset", .{scenario.source}));
    try std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ scenario.source, assets[0] }));
    try std.Io.Dir.cwd().deleteFile(io, try std.fmt.allocPrint(allocator, "{s}/display/{s}", .{ scenario.source, assets[1] }));
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/thumb/{s}", .{ scenario.source, assets[2] }), "modified");
    const shardDir = try std.fmt.allocPrint(allocator, "{s}/.db/bson/collections/metadata/shards", .{scenario.source});
    for (try listFiles(allocator, io, shardDir)) |shardFile| {
        if (!std.mem.endsWith(u8, shardFile, ".dat")) {
            const shardPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ shardDir, shardFile });
            const shard = try helpers.readFile(allocator, io, shardPath);
            shard[shard.len - 1] ^= 0xff;
            try helpers.writeFile(io, shardPath, shard);
            break;
        }
    }
    try expectVerifyMatchesTypeScript(allocator, io, scenario.source, null, try tsInspect(allocator, io, scenario.source, null));
}

test "replicating plain to encrypted and encrypted to plain matches TypeScript and TypeScript reads the results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const scenario = try makeScenario(allocator, io, "v6");
    defer helpers.removeTempDir(io, scenario.root);

    // Plain to encrypted.
    _ = try replicateBoth(allocator, io, scenario, false, KEY_FILE, null);
    try std.testing.expectEqualStrings(
        try helpers.readFile(allocator, io, helpers.KEYS_DIR ++ "/ts-public.pem"),
        try helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{scenario.zigReplica})),
    );
    try expectReplicaMatchesSource(allocator, io, scenario.source, scenario.zigReplica, null, KEY_FILE, false);

    // Encrypted to plain (the Zig encrypted replica is the source of both).
    const encryptedScenario: Scenario = .{
        .root = scenario.root,
        .source = scenario.zigReplica,
        .zigReplica = try std.fmt.allocPrint(allocator, "{s}/zig-plain", .{scenario.root}),
        .tsReplica = try std.fmt.allocPrint(allocator, "{s}/ts-plain", .{scenario.root}),
        .zigCounter = try std.fmt.allocPrint(allocator, "{s}/zig-plain-counter", .{scenario.root}),
        .tsCounter = try std.fmt.allocPrint(allocator, "{s}/ts-plain-counter", .{scenario.root}),
    };
    _ = try replicateBoth(allocator, io, encryptedScenario, false, null, KEY_FILE);
    try expectReplicaMatchesSource(allocator, io, scenario.zigReplica, encryptedScenario.zigReplica, KEY_FILE, null, false);
}
