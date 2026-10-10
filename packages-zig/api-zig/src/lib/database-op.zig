const std = @import("std");
const op = @import("op.zig");

//
// An operation on a record of a database, and the database it applies to.
//
pub const IDatabaseOp = struct {
    // The database the operation is applied to.
    databaseId: []const u8,

    // The name of the database collection to which the operation is applied.
    collectionName: []const u8,

    // The id of the asset to which operations are applied.
    recordId: []const u8,

    // The operation to apply to the asset.
    op: op.IOpSelection,
};

//
// Reads an operation from the JSON object the page sends.
//
pub fn databaseOpFromJson(value: std.json.Value) !IDatabaseOp {
    if (value != .object) {
        return error.InvalidOp;
    }
    const database_id = value.object.get("databaseId") orelse {
        return error.InvalidOp;
    };
    const collection_name = value.object.get("collectionName") orelse {
        return error.InvalidOp;
    };
    const record_id = value.object.get("recordId") orelse {
        return error.InvalidOp;
    };
    const op_value = value.object.get("op") orelse {
        return error.InvalidOp;
    };
    if (database_id != .string or collection_name != .string or record_id != .string) {
        return error.InvalidOp;
    }
    return .{
        .databaseId = database_id.string,
        .collectionName = collection_name.string,
        .recordId = record_id.string,
        .op = try op.opSelectionFromJson(op_value),
    };
}
