//
// TypeScript ends each listing loop with `while (next)`, so a storage that answers an empty continuation token ends the
// listing like one that answers none. These tests list through a storage that answers "" where it would answer
// nothing, and fail if anything asks it for the page after an empty token.
//

const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const IStorage = storage_zig.storage.IStorage;
const IListResult = storage_zig.storage.IListResult;

const io = std.testing.io;

//
// A valid record id.
//
const RECORD_ID = "11111111-1111-4111-a111-111111111111";

//
// Generates tree ids.
//
var test_uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

//
// Fails a listing that continues from an empty token, and answers "" in place of no token.
//
fn answerEmptyToken(next: ?[]const u8, result: IListResult) !IListResult {
    if (next != null and next.?.len == 0) {
        return error.ListedAgainAfterAnEmptyToken;
    }
    var answer = result;
    if (answer.next == null) {
        answer.next = "";
    }
    return answer;
}

//
// MemoryStorage.listFiles, answering "" in place of no continuation token.
//
fn listFilesWithEmptyToken(ptr: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
    const memoryStorage: *MemoryStorage = @ptrCast(@alignCast(ptr));
    if (next != null and next.?.len == 0) {
        return error.ListedAgainAfterAnEmptyToken;
    }
    return answerEmptyToken(next, try memoryStorage.listFiles(allocator, ioValue, path, max, next));
}

//
// MemoryStorage.listDirs, answering "" in place of no continuation token.
//
fn listDirsWithEmptyToken(ptr: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
    const memoryStorage: *MemoryStorage = @ptrCast(@alignCast(ptr));
    if (next != null and next.?.len == 0) {
        return error.ListedAgainAfterAnEmptyToken;
    }
    return answerEmptyToken(next, try memoryStorage.listDirs(allocator, ioValue, path, max, next));
}

//
// The vtable of MemoryStorage with the two listings replaced.
//
var empty_token_vtable: IStorage.VTable = undefined;

//
// Gets an IStorage over the memory storage whose listings answer "" in place of no continuation token.
//
fn emptyTokenStorage(memoryStorage: *MemoryStorage) IStorage {
    empty_token_vtable = storage_zig.storage.implement(MemoryStorage).*;
    empty_token_vtable.listFiles = listFilesWithEmptyToken;
    empty_token_vtable.listDirs = listDirsWithEmptyToken;
    return .{
        .ptr = memoryStorage,
        .vtable = &empty_token_vtable,
        .location = "memory://mock",
    };
}

//
// Writes one record into collection "users" and commits it through a normal storage.
//
fn writeOneRecord(allocator: std.mem.Allocator, memoryStorage: *MemoryStorage) !void {
    const database = try bdb.database.BsonDatabase.init(allocator, memoryStorage.asStorage(), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    const collection = try database.collection("users");
    try collection.setInternalRecord(io, .{
        ._id = RECORD_ID,
        .fields = try BsonDocument.fromFields(allocator, &.{.{ .key = "name", .value = .{ .string = "Ann" } }}),
        .metadata = .empty,
    });
    try database.commit(io);
}

test "BsonDatabase.collections stops listing on an empty continuation token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    try writeOneRecord(allocator, &memoryStorage);

    const database = try bdb.database.BsonDatabase.init(allocator, emptyTokenStorage(&memoryStorage), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    const names = try database.collections(io);
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("users", names[0]);
}

test "BsonCollection.iterateShards stops listing on an empty continuation token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    try writeOneRecord(allocator, &memoryStorage);

    const database = try bdb.database.BsonDatabase.init(allocator, emptyTokenStorage(&memoryStorage), "", test_uuid_generator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
    const collection = try database.collection("users");
    var shards = collection.iterateShards();
    const firstShard = (try shards.next(io)).?;
    try std.testing.expectEqual(@as(usize, 1), firstShard.len);
    try std.testing.expectEqualStrings(RECORD_ID, firstShard[0]._id);
    try std.testing.expect(try shards.next(io) == null);
}

test "listShards stops listing on an empty continuation token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    try writeOneRecord(allocator, &memoryStorage);

    const shardIds = try bdb.merkle_tree.listShards(allocator, io, emptyTokenStorage(&memoryStorage), "", "users");
    try std.testing.expectEqual(@as(usize, 1), shardIds.len);
}

test "buildDatabaseMerkleTree stops listing collections on an empty continuation token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    try writeOneRecord(allocator, &memoryStorage);

    const tree = try bdb.merkle_tree.buildDatabaseMerkleTree(allocator, io, emptyTokenStorage(&memoryStorage), "", test_uuid_generator.uuidGenerator(), null, null, true);
    try std.testing.expect(tree.merkle != null or tree.sort != null);
}
