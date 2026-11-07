const std = @import("std");
const api_zig = @import("api-zig");
const ISaveAssetItem = api_zig.save_assets_types.ISaveAssetItem;

test "ISaveAssetItem reads the keys the interface names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = "{\"assetId\":\"asset-1\",\"assetType\":\"display\",\"filename\":\"holiday.jpg\"}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});

    const item = try std.json.parseFromValueLeaky(ISaveAssetItem, allocator, value, .{});

    try std.testing.expectEqualStrings("asset-1", item.assetId);
    try std.testing.expectEqualStrings("display", item.assetType);
    try std.testing.expectEqualStrings("holiday.jpg", item.filename);
}

test "ISaveAssetItem refuses an item that leaves out a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"assetId\":\"asset-1\",\"assetType\":\"display\"}", .{});

    try std.testing.expectError(error.MissingField, std.json.parseFromValueLeaky(ISaveAssetItem, allocator, value, .{}));
}
