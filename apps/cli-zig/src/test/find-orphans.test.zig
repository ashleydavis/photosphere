const std = @import("std");
const cli = @import("cli-zig");
const node_api = @import("node-api-zig");
const storage_zig = @import("storage-zig");
const helpers = @import("test-helpers.zig");
const findOrphans = cli.find_orphans.findOrphans;

//
// Writes a file of one byte, making its directory.
//
fn writeStray(allocator: std.mem.Allocator, db: []const u8, fileName: []const u8) !void {
    const filePath = try std.fs.path.join(allocator, &.{ db, fileName });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(filePath).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = filePath,
        .data = "x",
    });
}

test "findOrphans lists the files that are not in the merkle tree, skipping .db, metadata and .DS_Store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "find-orphans");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", db);
    try writeStray(allocator, db, "asset/orphan-1");
    try writeStray(allocator, db, ".db/stray");
    try writeStray(allocator, db, "metadata/stray");
    try writeStray(allocator, db, ".DS_Store");
    try writeStray(allocator, db, "other/file");

    const created = try storage_zig.storage_factory.createStorage(allocator, io, db, null, null);
    const merkleTree = (try node_api.tree.loadMerkleTree(allocator, io, created.storage)).?;
    const orphans = try findOrphans(allocator, io, created.storage, &merkleTree);

    try std.testing.expectEqual(@as(usize, 2), orphans.len);
    try std.testing.expectEqualStrings("asset/orphan-1", orphans[0]);
    try std.testing.expectEqualStrings("other/file", orphans[1]);
}

test "findOrphans finds nothing in a database without strays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "find-orphans-none");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", db);

    const created = try storage_zig.storage_factory.createStorage(allocator, io, db, null, null);
    const merkleTree = (try node_api.tree.loadMerkleTree(allocator, io, created.storage)).?;
    const orphans = try findOrphans(allocator, io, created.storage, &merkleTree);

    try std.testing.expectEqual(@as(usize, 0), orphans.len);
}
