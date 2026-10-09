const std = @import("std");

//
// Operations to apply to a database record (TypeScript: IOp, ISetOp, IPushOp, IPullOp and the IOpSelection that is any one of
// them).
//
// (Zig: the type of an operation is the tag of the union, so IOp, whose only field is that type, is not a type of its own. A value
// an operation holds is any JSON value, the way the TypeScript `any` is.)
//

//
// An operation to set fields on a database record.
//
pub const ISetOp = struct {
    // The fields/values to set (a JSON object).
    fields: std.json.ObjectMap,
};

//
// An operation to push a value into an array.
//
pub const IPushOp = struct {
    // The field to push to.
    field: []const u8,

    // The value to push.
    value: std.json.Value,
};

//
// An operation to pull a value from an array.
//
pub const IPullOp = struct {
    // The field to pull from.
    field: []const u8,

    // The value to pull.
    value: std.json.Value,
};

//
// Specifies the range of possible operations.
//
pub const IOpSelection = union(enum) {
    // Sets the value of fields.
    set: ISetOp,

    // Pushes a value into an array.
    push: IPushOp,

    // Pulls a value from an array.
    pull: IPullOp,
};

//
// Reads an operation from the JSON object the page sends: `{ type: "set", fields }`, `{ type: "push", field, value }` or
// `{ type: "pull", field, value }`. (No TypeScript counterpart: TypeScript trusts the shape of the parsed JSON, and a
// malformed operation fails later, where a missing property is read. Here it fails when it is read, with a message that says
// which part is wrong.)
//
pub fn opSelectionFromJson(value: std.json.Value) !IOpSelection {
    if (value != .object) {
        return error.InvalidOp;
    }
    const type_value = value.object.get("type") orelse {
        return error.InvalidOp;
    };
    if (type_value != .string) {
        return error.InvalidOp;
    }
    if (std.mem.eql(u8, type_value.string, "set")) {
        const fields = value.object.get("fields") orelse {
            return error.InvalidOp;
        };
        if (fields != .object) {
            return error.InvalidOp;
        }
        return .{
            .set = .{
                .fields = fields.object,
            },
        };
    }
    const field_value = value.object.get("field") orelse {
        return error.InvalidOp;
    };
    if (field_value != .string) {
        return error.InvalidOp;
    }
    const op_value = value.object.get("value") orelse std.json.Value.null;
    if (std.mem.eql(u8, type_value.string, "push")) {
        return .{
            .push = .{
                .field = field_value.string,
                .value = op_value,
            },
        };
    }
    if (std.mem.eql(u8, type_value.string, "pull")) {
        return .{
            .pull = .{
                .field = field_value.string,
                .value = op_value,
            },
        };
    }
    return error.InvalidOp;
}
