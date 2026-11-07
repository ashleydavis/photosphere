const std = @import("std");
const api_zig = @import("api-zig");
const database_op = api_zig.database_op;

//
// Parses a JSON literal.
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

test "an operation on a record holds the database, the collection, the record and the operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const databaseOp = try database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":"metadata","recordId":"asset-1","op":{"type":"push","field":"labels","value":"holiday"}}
    ));

    try std.testing.expectEqualStrings("db-1", databaseOp.databaseId);
    try std.testing.expectEqualStrings("metadata", databaseOp.collectionName);
    try std.testing.expectEqualStrings("asset-1", databaseOp.recordId);
    try std.testing.expectEqualStrings("labels", databaseOp.op.push.field);
}

test "an operation that is not an object is refused" {
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(.null));
}

test "an operation missing the database, the collection, the record or the op is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"collectionName":"metadata","recordId":"asset-1","op":{"type":"set","fields":{}}}
    )));
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","recordId":"asset-1","op":{"type":"set","fields":{}}}
    )));
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":"metadata","op":{"type":"set","fields":{}}}
    )));
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":"metadata","recordId":"asset-1"}
    )));
}

test "an operation whose database, collection or record is not a string is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":1,"collectionName":"metadata","recordId":"asset-1","op":{"type":"set","fields":{}}}
    )));
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":1,"recordId":"asset-1","op":{"type":"set","fields":{}}}
    )));
    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":"metadata","recordId":1,"op":{"type":"set","fields":{}}}
    )));
}

test "an operation holding an operation that is refused is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, database_op.databaseOpFromJson(try parseJson(allocator,
        \\{"databaseId":"db-1","collectionName":"metadata","recordId":"asset-1","op":{"type":"delete"}}
    )));
}
