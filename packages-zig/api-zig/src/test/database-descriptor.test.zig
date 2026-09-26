const std = @import("std");
const api_zig = @import("api-zig");
const IDatabaseDescriptor = api_zig.database_descriptor.IDatabaseDescriptor;

test "IDatabaseDescriptor parses from task data JSON with and without the optional key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const without_key = try std.json.parseFromSliceLeaky(IDatabaseDescriptor, allocator, "{\"databasePath\":\"fs:/db\"}", .{});
    try std.testing.expectEqualStrings("fs:/db", without_key.databasePath);
    try std.testing.expect(without_key.encryptionKey == null);

    const with_key = try std.json.parseFromSliceLeaky(IDatabaseDescriptor, allocator, "{\"databasePath\":\"s3:b:/db\",\"encryptionKey\":\"my-key\"}", .{});
    try std.testing.expectEqualStrings("my-key", with_key.encryptionKey.?);
}

test "IDatabaseDescriptor serializes with the TypeScript field names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const descriptor: IDatabaseDescriptor = .{ .databasePath = "fs:/db", .encryptionKey = null };
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), descriptor, .{ .emit_null_optional_fields = false });
    try std.testing.expectEqualStrings("{\"databasePath\":\"fs:/db\"}", json);
}
