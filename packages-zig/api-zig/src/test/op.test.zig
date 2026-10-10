const std = @import("std");
const api_zig = @import("api-zig");
const op = api_zig.op;

//
// Parses a JSON literal.
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

test "a set operation holds the fields to set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const selection = try op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"set","fields":{"description":"a photo","favorite":true}}
    ));

    try std.testing.expectEqual(@as(usize, 2), selection.set.fields.count());
    try std.testing.expectEqualStrings("a photo", selection.set.fields.get("description").?.string);
    try std.testing.expectEqual(true, selection.set.fields.get("favorite").?.bool);
}

test "a push operation holds the field and the value to push" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const selection = try op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"push","field":"labels","value":"holiday"}
    ));

    try std.testing.expectEqualStrings("labels", selection.push.field);
    try std.testing.expectEqualStrings("holiday", selection.push.value.string);
}

test "a pull operation holds the field and the value to pull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const selection = try op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"pull","field":"labels","value":"holiday"}
    ));

    try std.testing.expectEqualStrings("labels", selection.pull.field);
    try std.testing.expectEqualStrings("holiday", selection.pull.value.string);
}

test "a push or pull with no value holds null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const push = try op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"push","field":"labels"}
    ));
    const pull = try op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"pull","field":"labels"}
    ));

    try std.testing.expect(push.push.value == .null);
    try std.testing.expect(pull.pull.value == .null);
}

test "an operation that is not an object is refused" {
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(.null));
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(.{
        .string = "set",
    }));
}

test "an operation with no type, or a type that is not a string, or an unknown type, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"field":"labels","value":1}
    )));
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":1,"field":"labels","value":1}
    )));
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"delete","field":"labels","value":1}
    )));
}

test "a set with no fields, or fields that are not an object, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"set"}
    )));
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"set","fields":[1]}
    )));
}

test "a push or pull with no field, or a field that is not a string, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"push","value":1}
    )));
    try std.testing.expectError(error.InvalidOp, op.opSelectionFromJson(try parseJson(allocator,
        \\{"type":"pull","field":5,"value":1}
    )));
}
