const std = @import("std");
const api_zig = @import("api-zig");
const types = api_zig.replicate_database_types;

test "IReplicateDatabaseData round-trips through task data JSON (JSON.stringify drops undefined keys)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // What TypeScript sends for { sourcePath, destPath, destS3Key: undefined, partial, force }.
    const json = "{\"sourcePath\":\"/src\",\"destPath\":\"s3:bucket:/dest\",\"partial\":true,\"force\":false}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const data = try std.json.parseFromValueLeaky(types.IReplicateDatabaseData, allocator, value, .{});
    try std.testing.expectEqualStrings("/src", data.sourcePath);
    try std.testing.expectEqualStrings("s3:bucket:/dest", data.destPath);
    try std.testing.expect(data.sourceEncryptionKey == null);
    try std.testing.expect(data.destEncryptionKey == null);
    try std.testing.expect(data.destS3Key == null);
    try std.testing.expect(data.pathFilter == null);
    try std.testing.expect(data.partial);
    try std.testing.expect(!data.force);

    const round_trip = try std.json.Stringify.valueAlloc(allocator, data, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqualStrings(json, round_trip);
}

test "IReplicateDatabaseData reads every optional key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = "{\"sourcePath\":\"a\",\"destPath\":\"b\",\"sourceEncryptionKey\":\"sk\",\"destEncryptionKey\":\"dk\",\"destS3Key\":\"s3\",\"partial\":false,\"force\":true,\"pathFilter\":\"asset/x\"}";
    const data = try std.json.parseFromSliceLeaky(types.IReplicateDatabaseData, arena.allocator(), json, .{});
    try std.testing.expectEqualStrings("sk", data.sourceEncryptionKey.?);
    try std.testing.expectEqualStrings("dk", data.destEncryptionKey.?);
    try std.testing.expectEqualStrings("s3", data.destS3Key.?);
    try std.testing.expectEqualStrings("asset/x", data.pathFilter.?);
    try std.testing.expect(data.force);
}

test "IReplicateProgressMessage serializes like the TypeScript message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message: types.IReplicateProgressMessage = .{ .type = "replicate-progress", .databasePath = "/db", .progress = "Copied 1 file" };
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), message, .{});
    try std.testing.expectEqualStrings("{\"type\":\"replicate-progress\",\"databasePath\":\"/db\",\"progress\":\"Copied 1 file\"}", json);
}
