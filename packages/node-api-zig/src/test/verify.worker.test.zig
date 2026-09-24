const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const verify_worker = node_api.verify_worker;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const TaskContext = task_queue_zig.task_context.TaskContext;

//
// The thumbnail of the asset in test/dbs/v6.
//
const THUMB_PATH = "thumb/89171cd9-a652-4047-b869-1154bf2c95a1";

//
// Ignores task messages.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// Runs the handler for the tree leaf of a file of a database.
//
fn runHandler(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8, fileName: []const u8, adjust: *const fn (*SortNode) void) !verify_worker.IVerifyFileResult {
    _ = try helpers.setupEnvironment(io);
    const storage = try helpers.directoryStorage(allocator, io, databaseDir);
    const tree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    const leaf = merkle_tree_zig.merkle_tree.findItemInTree(tree.sort, fileName).?;
    var node = leaf.*;
    adjust(&node);
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider = .{};
    var context = TaskContext.init(uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider(), "session", "task", .{ .context = null, .function = ignoreMessage });
    const data = try verify_worker.verifyFileDataToJson(allocator, .{ .node = node, .storageDescriptor = .{ .databasePath = databaseDir }, .options = .{ .full = false } });
    const output = try verify_worker.verifyFileHandler(allocator, io, data, context.taskContext());
    return std.json.parseFromValueLeaky(verify_worker.IVerifyFileResult, allocator, output, .{});
}

//
// Leaves the node as it is.
//
fn keepNode(node: *SortNode) void {
    _ = node;
}

//
// Makes the node's timestamp differ from the file's.
//
fn changeTimestamp(node: *SortNode) void {
    node.lastModified = 0;
}

//
// Makes the node's size and timestamp differ from the file's.
//
fn changeSizeAndTimestamp(node: *SortNode) void {
    node.lastModified = 0;
    node.size = 1536;
}

test "verifyFileHandler reports unmodified, removed and modified files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const databaseDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ databaseDir, THUMB_PATH });

    // The copy has new timestamps, so the handler hashes the file and finds the content unchanged.
    const unmodified = try runHandler(allocator, io, databaseDir, THUMB_PATH, keepNode);
    try std.testing.expectEqual(verify_worker.VerifyFileStatus.unmodified, unmodified.status);
    try std.testing.expectEqualStrings(THUMB_PATH, unmodified.fileName);

    // Content changed: modified with the reasons.
    try helpers.writeFile(io, filePath, "changed");
    const modified = try runHandler(allocator, io, databaseDir, THUMB_PATH, changeSizeAndTimestamp);
    try std.testing.expectEqual(verify_worker.VerifyFileStatus.modified, modified.status);
    try std.testing.expectEqual(@as(usize, 3), modified.reasons.?.len);
    try std.testing.expectEqualStrings("size changed (1.5 KB → 7 B)", modified.reasons.?[0]);
    try std.testing.expect(std.mem.startsWith(u8, modified.reasons.?[1], "timestamp changed (1/1/1970, 12:00:00 AM → "));
    try std.testing.expectEqualStrings("content hash changed", modified.reasons.?[2]);

    // Missing file: removed.
    try std.Io.Dir.cwd().deleteFile(io, filePath);
    const removed = try runHandler(allocator, io, databaseDir, THUMB_PATH, changeTimestamp);
    try std.testing.expectEqual(verify_worker.VerifyFileStatus.removed, removed.status);
    try std.testing.expect(removed.reasons == null);
}

test "verifyFileHandler does not hash a file whose size and timestamp are unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const databaseDir = try helpers.copyTestDatabase(allocator, io, "v6");
    defer helpers.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    const storage = try helpers.directoryStorage(allocator, io, databaseDir);

    // Corrupt the content but keep the size, and give the tree the new timestamp: only a hash would notice.
    const original = (try storage.read(allocator, io, THUMB_PATH)).?;
    const corrupted = try allocator.dupe(u8, original);
    corrupted[0] ^= 0xff;
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ databaseDir, THUMB_PATH }), corrupted);
    const info = (try storage.info(allocator, io, THUMB_PATH)).?;
    const Adjust = struct {
        var lastModified: i64 = 0;
        fn call(node: *SortNode) void {
            node.lastModified = lastModified;
        }
    };
    Adjust.lastModified = info.lastModified;
    const result = try runHandler(allocator, io, databaseDir, THUMB_PATH, Adjust.call);
    try std.testing.expectEqual(verify_worker.VerifyFileStatus.unmodified, result.status);
}

test "verifyFileDataToJson and verifyFileDataFromJson round trip a leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const hash = [_]u8{ 0xab, 0x01 } ** 16;
    const data: verify_worker.IVerifyFileData = .{
        .node = .{ .contentHash = &hash, .name = "asset/x", .nodeCount = 1, .leafCount = 1, .size = 42, .lastModified = 1234, .minName = "asset/x" },
        .storageDescriptor = .{ .databasePath = "/db", .encryptionKey = "key" },
        .options = .{ .full = true },
    };
    const value = try verify_worker.verifyFileDataToJson(allocator, data);
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    const back = try verify_worker.verifyFileDataFromJson(allocator, parsed);
    try std.testing.expectEqualSlices(u8, &hash, back.node.contentHash.?);
    try std.testing.expectEqualStrings("asset/x", back.node.name.?);
    try std.testing.expectEqual(@as(u64, 42), back.node.size);
    try std.testing.expectEqual(@as(?i64, 1234), back.node.lastModified);
    try std.testing.expectEqualStrings("/db", back.storageDescriptor.databasePath);
    try std.testing.expectEqualStrings("key", back.storageDescriptor.encryptionKey.?);
    try std.testing.expectEqual(@as(?bool, true), back.options.?.full);
}

test "toLocaleString formats dates like Date.toLocaleString in en-US" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("1/1/2020, 1:05:07 PM", try verify_worker.toLocaleString(allocator, 1577836800000 + 13 * 3600000 + 5 * 60000 + 7000));
    try std.testing.expectEqualStrings("1/1/1970, 12:00:00 AM", try verify_worker.toLocaleString(allocator, 0));
    try std.testing.expectEqualStrings("1/1/1970, 12:00:00 PM", try verify_worker.toLocaleString(allocator, 43200000));
}
