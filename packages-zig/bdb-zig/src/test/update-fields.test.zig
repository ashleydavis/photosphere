const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const updateFields = bdb.update_fields.updateFields;
const property = helpers.property;
const stringValue = helpers.stringValue;
const numberValue = helpers.numberValue;
const objectValue = helpers.objectValue;

//
// Asserts that a value deep equals the expected value (TypeScript: `expect(result).toEqual(expected)`).
//
fn expectEqualValue(expected: BsonValue, actual: BsonValue) !void {
    try std.testing.expect(actual.eql(expected));
}

test "should return original fields when no updates provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const result = try updateFields(allocator, fields, try objectValue(allocator, &.{}));
    try std.testing.expect(result.document.fields.items.ptr == fields.document.fields.items.ptr); // Returns original when no updates.
}

test "should update simple fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{property("name", stringValue("Jane"))});
    const result = try updateFields(allocator, fields, updates);
    try std.testing.expect(result.document.fields.items.ptr != fields.document.fields.items.ptr); // Returns new object.
    try expectEqualValue(try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("age", numberValue(30)) }), result);
}

test "should add new fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const updates = try objectValue(allocator, &.{property("age", numberValue(30))});
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) }), result);
}

test "should delete fields set to undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) });
    const updates = try objectValue(allocator, &.{property("age", .undefined)});
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{property("name", stringValue("John"))}), result);
    try std.testing.expect(result.document.get("age") == null);
}

test "should recursively merge nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
            property("zip", stringValue("10001")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
        })),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("NYC")),
            property("zip", stringValue("10001")),
        })),
    }), result);
}

test "should replace nested object when old value is not an object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", stringValue("old address")),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    }), result);
}

test "should replace nested object when new value is not an object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", stringValue("simple string")),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", stringValue("simple string")),
    }), result);
}

test "should handle deeply nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("user", try objectValue(allocator, &.{
            property("name", stringValue("John")),
            property("profile", try objectValue(allocator, &.{
                property("age", numberValue(30)),
                property("contact", try objectValue(allocator, &.{
                    property("email", stringValue("john@example.com")),
                    property("phone", stringValue("555-1234")),
                })),
            })),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("user", try objectValue(allocator, &.{
            property("profile", try objectValue(allocator, &.{
                property("contact", try objectValue(allocator, &.{
                    property("email", stringValue("john.new@example.com")),
                })),
            })),
        })),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("user", try objectValue(allocator, &.{
            property("name", stringValue("John")),
            property("profile", try objectValue(allocator, &.{
                property("age", numberValue(30)),
                property("contact", try objectValue(allocator, &.{
                    property("email", stringValue("john.new@example.com")),
                    property("phone", stringValue("555-1234")),
                })),
            })),
        })),
    }), result);
}

test "should delete nested fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
            property("zip", stringValue("10001")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", try objectValue(allocator, &.{
            property("zip", .undefined),
        })),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    }), result);
    try std.testing.expect(result.document.get("address").?.document.get("zip") == null);
}

test "should handle empty objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{});
    const updates = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{property("name", stringValue("John"))}), result);
}

test "should handle null oldFields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields: BsonValue = .null;
    const updates = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{property("name", stringValue("John"))}), result);
}

test "should handle undefined oldFields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields: BsonValue = .undefined;
    const updates = try objectValue(allocator, &.{property("name", stringValue("John"))});
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{property("name", stringValue("John"))}), result);
}

test "should not treat arrays as nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var oldTags = [_]BsonValue{ stringValue("a"), stringValue("b"), stringValue("c") };
    var newTags = [_]BsonValue{ stringValue("x"), stringValue("y") };
    var expectedTags = [_]BsonValue{ stringValue("x"), stringValue("y") };
    const fields = try objectValue(allocator, &.{
        property("tags", .{ .array = &oldTags }),
    });
    const updates = try objectValue(allocator, &.{
        property("tags", .{ .array = &newTags }),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("tags", .{ .array = &expectedTags }),
    }), result);
    // Arrays should be replaced, not merged
    try expectEqualValue(.{ .array = &expectedTags }, result.document.get("tags").?);
}

test "should handle multiple updates at once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("age", numberValue(30)),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(31)),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
        })),
        property("email", stringValue("jane@example.com")),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(31)),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("456 Oak Ave")),
            property("city", stringValue("NYC")),
        })),
        property("email", stringValue("jane@example.com")),
    }), result);
}

test "should handle deleting entire nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fields = try objectValue(allocator, &.{
        property("name", stringValue("John")),
        property("address", try objectValue(allocator, &.{
            property("street", stringValue("123 Main St")),
            property("city", stringValue("NYC")),
        })),
    });
    const updates = try objectValue(allocator, &.{
        property("address", .undefined),
    });
    const result = try updateFields(allocator, fields, updates);
    try expectEqualValue(try objectValue(allocator, &.{
        property("name", stringValue("John")),
    }), result);
    try std.testing.expect(result.document.get("address") == null);
}
