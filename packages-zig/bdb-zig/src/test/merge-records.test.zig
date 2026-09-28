//
// Tests for mergeRecords (port of src/tests/merge-records.test.ts).
//

const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const Metadata = bdb.collection.Metadata;
const IInternalRecord = bdb.shard.IInternalRecord;
const mergeRecords = bdb.merge_records.mergeRecords;
const property = helpers.property;
const stringValue = helpers.stringValue;
const numberValue = helpers.numberValue;
const objectValue = helpers.objectValue;

//
// Builds a JS object literal as a document.
//
fn documentOf(allocator: std.mem.Allocator, properties: []const bson.BsonField) !BsonDocument {
    return (try objectValue(allocator, properties)).document;
}

//
// Builds the leaf metadata literal `{ timestamp }`.
//
fn leaf(allocator: std.mem.Allocator, timestamp: f64) !BsonValue {
    return objectValue(allocator, &.{property("timestamp", numberValue(timestamp))});
}

//
// Builds a record literal.
//
fn record(allocator: std.mem.Allocator, id: []const u8, fields: []const bson.BsonField, metadata: []const bson.BsonField) !IInternalRecord {
    return .{
        ._id = id,
        .fields = try documentOf(allocator, fields),
        .metadata = try documentOf(allocator, metadata),
    };
}

//
// Returns `value[key]` for a document value (undefined when it has no such field).
//
fn get(value: BsonValue, key: []const u8) BsonValue {
    if (value != .document) {
        return .undefined;
    }
    return value.document.get(key) orelse .undefined;
}

//
// Returns `metadata.fields` (undefined when it has none).
//
fn fieldsOf(metadata: Metadata) BsonValue {
    return metadata.get("fields") orelse .undefined;
}

//
// Jest's toEqual: deep equality that ignores properties whose value is undefined and the order of properties.
//
fn toEqual(actual: BsonValue, expected: BsonValue) bool {
    if (actual == .document and expected == .document) {
        for (expected.document.fields.items) |field| {
            if (field.value == .undefined) {
                continue;
            }
            if (!toEqual(actual.document.get(field.key) orelse .undefined, field.value)) {
                return false;
            }
        }
        for (actual.document.fields.items) |field| {
            if (field.value == .undefined) {
                continue;
            }
            if ((expected.document.get(field.key) orelse BsonValue.undefined) == .undefined) {
                return false;
            }
        }
        return true;
    }
    return actual.eql(expected);
}

test "should merge two records with same _id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{ property("name", stringValue("John")), property("age", numberValue(30)) }, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expectEqualStrings("123", result._id);
    try std.testing.expect(toEqual(.{ .document = result.fields }, try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(30)),
        property("email", stringValue("jane@example.com")),
    })));
}

test "should throw error when records have different _id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "456", &.{property("name", stringValue("Jane"))}, &.{property("timestamp", numberValue(2000))});

    try std.testing.expectError(error.Thrown, mergeRecords(allocator, record1, record2));
    try std.testing.expectEqualStrings("Cannot merge records with different IDs: 123 vs 456", utils.errors.lastErrorMessage());
}

test "should merge records with field-level metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{ property("name", stringValue("John")), property("age", numberValue(30)) }, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{property("name", try leaf(allocator, 1500))})),
    });
    const record2 = try record(allocator, "123", &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{property("email", try leaf(allocator, 2000))})),
    });

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expect(get(.{ .document = result.fields }, "name").eql(stringValue("Jane"))); // value2.name timestamp 2000 > value1.name timestamp 1500
    try std.testing.expect(get(.{ .document = result.fields }, "age").eql(numberValue(30)));
    try std.testing.expect(get(.{ .document = result.fields }, "email").eql(stringValue("jane@example.com")));
    try std.testing.expect(fieldsOf(result.metadata) != .undefined);
}

test "should handle records with no metadata timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{}); // no timestamp
    const record2 = try record(allocator, "123", &.{property("name", stringValue("Jane"))}, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    // record1 timestamp defaults to 0, record2 is 2000
    // So record2.name should win
    try std.testing.expect(get(.{ .document = result.fields }, "name").eql(stringValue("Jane")));
}

test "should merge nested objects in records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) })),
        property("settings", try objectValue(allocator, &.{property("theme", stringValue("dark"))})),
    }, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) })),
        property("settings", try objectValue(allocator, &.{ property("theme", stringValue("light")), property("fontSize", numberValue(14)) })),
    }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expect(toEqual(get(.{ .document = result.fields }, "user"), try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(30)),
        property("email", stringValue("jane@example.com")),
    })));
    try std.testing.expect(toEqual(get(.{ .document = result.fields }, "settings"), try objectValue(allocator, &.{
        property("theme", stringValue("light")),
        property("fontSize", numberValue(14)),
    })));
}

test "should clean up empty metadata after merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{property("name", stringValue("Jane"))}, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    // After cleanup with timestamp 0, the metadata should have fields
    // because name has timestamp 2000 > 0
    try std.testing.expect(fieldsOf(result.metadata) != .undefined);
    try std.testing.expect(get(fieldsOf(result.metadata), "name") != .undefined);
}

test "should handle records with all fields having old timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{property("name", stringValue("Jane"))}, &.{property("timestamp", numberValue(500))});

    const result = try mergeRecords(allocator, record1, record2);

    // record1.name wins (timestamp 1000 > 500)
    // After cleanup with timestamp 0, name has timestamp 1000 > 0, so should be preserved
    try std.testing.expect(get(.{ .document = result.fields }, "name").eql(stringValue("John")));
    try std.testing.expect(fieldsOf(result.metadata) != .undefined);
    try std.testing.expect(get(get(fieldsOf(result.metadata), "name"), "timestamp").eql(numberValue(1000)));
}

test "should merge records with deeply nested structures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{
        property("level1", try objectValue(allocator, &.{
            property("level2", try objectValue(allocator, &.{
                property("level3", try objectValue(allocator, &.{property("value", stringValue("deep1"))})),
            })),
        })),
    }, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{
        property("level1", try objectValue(allocator, &.{
            property("level2", try objectValue(allocator, &.{
                property("level3", try objectValue(allocator, &.{ property("value", stringValue("deep2")), property("other", stringValue("field")) })),
            })),
        })),
    }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    const level3 = get(get(get(.{ .document = result.fields }, "level1"), "level2"), "level3");
    try std.testing.expect(get(level3, "value").eql(stringValue("deep2")));
    try std.testing.expect(get(level3, "other").eql(stringValue("field")));
}

test "should handle deleted fields in metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("email", try leaf(allocator, 500)), // deleted field
        })),
    });
    const record2 = try record(allocator, "123", &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) }, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{property("email", try leaf(allocator, 2000))})),
    });

    const result = try mergeRecords(allocator, record1, record2);

    // record2.email has newer timestamp, so it should win
    try std.testing.expect(get(.{ .document = result.fields }, "email").eql(stringValue("jane@example.com")));
}

test "should merge when one record has empty fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{}, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{ property("name", stringValue("Jane")), property("age", numberValue(25)) }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expect(toEqual(.{ .document = result.fields }, try objectValue(allocator, &.{
        property("name", stringValue("Jane")),
        property("age", numberValue(25)),
    })));
}

test "should handle records with no fields and no metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{}, &.{});
    const record2 = try record(allocator, "123", &.{}, &.{});

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expectEqualStrings("123", result._id);
    try std.testing.expect(toEqual(.{ .document = result.fields }, try objectValue(allocator, &.{})));
    try std.testing.expect(toEqual(.{ .document = result.metadata }, try objectValue(allocator, &.{})));
}

test "should preserve _id from first record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "abc-123", &.{property("name", stringValue("John"))}, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "abc-123", &.{property("name", stringValue("Jane"))}, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    try std.testing.expectEqualStrings("abc-123", result._id);
}

test "should handle complex field metadata with nested timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tags1 = [_]BsonValue{stringValue("tag1")};
    var tags2 = [_]BsonValue{stringValue("tag2")};
    const record1 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{ property("name", stringValue("John")), property("age", numberValue(30)) })),
        property("tags", .{ .array = &tags1 }),
    }, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{
                property("timestamp", numberValue(1500)),
                property("fields", try objectValue(allocator, &.{property("name", try leaf(allocator, 1500))})),
            })),
        })),
    });
    const record2 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{ property("name", stringValue("Jane")), property("email", stringValue("jane@example.com")) })),
        property("tags", .{ .array = &tags2 }),
    }, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{
                property("timestamp", numberValue(2000)),
                property("fields", try objectValue(allocator, &.{
                    property("name", try leaf(allocator, 2000)),
                    property("email", try leaf(allocator, 2000)),
                })),
            })),
        })),
    });

    const result = try mergeRecords(allocator, record1, record2);

    const user = get(.{ .document = result.fields }, "user");
    try std.testing.expect(get(user, "name").eql(stringValue("Jane")));
    try std.testing.expect(get(user, "age").eql(numberValue(30)));
    try std.testing.expect(get(user, "email").eql(stringValue("jane@example.com")));
}

test "should handle multiple field updates with different timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{ property("a", numberValue(1)), property("b", numberValue(2)), property("c", numberValue(3)) }, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("a", try leaf(allocator, 1500)),
            property("b", try leaf(allocator, 1200)),
        })),
    });
    const record2 = try record(allocator, "123", &.{ property("a", numberValue(10)), property("b", numberValue(20)), property("d", numberValue(4)) }, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{
            property("a", try leaf(allocator, 1800)),
            property("b", try leaf(allocator, 2500)),
            property("d", try leaf(allocator, 2000)),
        })),
    });

    const result = try mergeRecords(allocator, record1, record2);

    const fields: BsonValue = .{ .document = result.fields };
    try std.testing.expect(get(fields, "a").eql(numberValue(10))); // record2.a timestamp 1800 > record1.a timestamp 1500
    try std.testing.expect(get(fields, "b").eql(numberValue(20))); // record2.b timestamp 2500 > record1.b timestamp 1200
    try std.testing.expect(get(fields, "c").eql(numberValue(3))); // only in record1
    try std.testing.expect(get(fields, "d").eql(numberValue(4))); // only in record2
}

test "should handle records where cleanup removes all metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{property("name", stringValue("John"))}, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 500)), // old timestamp
        })),
    });
    const record2 = try record(allocator, "123", &.{property("name", stringValue("Jane"))}, &.{
        property("timestamp", numberValue(500)),
        property("fields", try objectValue(allocator, &.{
            property("name", try leaf(allocator, 300)), // old timestamp
        })),
    });

    const result = try mergeRecords(allocator, record1, record2);

    // After merge, name has timestamp 500 (record1.name with 500 > record2.name with 300)
    // After cleanup with timestamp 0, name timestamp 500 > 0, but cleanupMetadata may remove it
    // if the metadata structure doesn't meet the criteria
    try std.testing.expect(get(.{ .document = result.fields }, "name").eql(stringValue("John")));
    // The name field is in result.fields, but metadata.fields may be cleaned up
    // Check the actual behavior - if cleanup removes old metadata, fields might be undefined
    if (fieldsOf(result.metadata) != .undefined) {
        try std.testing.expect(get(fieldsOf(result.metadata), "name") != .undefined);
    }
}

test "should merge records with null and undefined values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{ property("name", stringValue("John")), property("age", .null), property("email", .undefined) }, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{ property("name", stringValue("Jane")), property("age", numberValue(30)) }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    const fields: BsonValue = .{ .document = result.fields };
    try std.testing.expect(get(fields, "name").eql(stringValue("Jane")));
    try std.testing.expect(get(fields, "age").eql(numberValue(30)));
    try std.testing.expect(get(fields, "email") == .undefined);
}

test "should handle arrays as field values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var items1 = [_]BsonValue{ numberValue(1), numberValue(2), numberValue(3) };
    var tags1 = [_]BsonValue{stringValue("a")};
    var items2 = [_]BsonValue{ numberValue(4), numberValue(5) };
    var tags2 = [_]BsonValue{ stringValue("b"), stringValue("c") };
    const record1 = try record(allocator, "123", &.{ property("items", .{ .array = &items1 }), property("tags", .{ .array = &tags1 }) }, &.{property("timestamp", numberValue(1000))});
    const record2 = try record(allocator, "123", &.{ property("items", .{ .array = &items2 }), property("tags", .{ .array = &tags2 }) }, &.{property("timestamp", numberValue(2000))});

    const result = try mergeRecords(allocator, record1, record2);

    // Arrays are objects, so they will be merged by keys
    try std.testing.expect(get(.{ .document = result.fields }, "items") != .undefined);
    try std.testing.expect(get(.{ .document = result.fields }, "tags") != .undefined);
}

test "should preserve metadata structure after merge and cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record1 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{
            property("name", stringValue("John")),
            property("profile", try objectValue(allocator, &.{property("bio", stringValue("Old bio"))})),
        })),
    }, &.{
        property("timestamp", numberValue(1000)),
        property("fields", try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{
                property("timestamp", numberValue(1000)),
                property("fields", try objectValue(allocator, &.{
                    property("profile", try objectValue(allocator, &.{
                        property("timestamp", numberValue(1000)),
                        property("fields", try objectValue(allocator, &.{property("bio", try leaf(allocator, 1000))})),
                    })),
                })),
            })),
        })),
    });
    const record2 = try record(allocator, "123", &.{
        property("user", try objectValue(allocator, &.{
            property("name", stringValue("Jane")),
            property("profile", try objectValue(allocator, &.{ property("bio", stringValue("New bio")), property("avatar", stringValue("avatar.jpg")) })),
        })),
    }, &.{
        property("timestamp", numberValue(2000)),
        property("fields", try objectValue(allocator, &.{
            property("user", try objectValue(allocator, &.{
                property("timestamp", numberValue(2000)),
                property("fields", try objectValue(allocator, &.{
                    property("name", try leaf(allocator, 2000)),
                    property("profile", try objectValue(allocator, &.{
                        property("timestamp", numberValue(2000)),
                        property("fields", try objectValue(allocator, &.{
                            property("bio", try leaf(allocator, 2000)),
                            property("avatar", try leaf(allocator, 2000)),
                        })),
                    })),
                })),
            })),
        })),
    });

    const result = try mergeRecords(allocator, record1, record2);

    const user = get(.{ .document = result.fields }, "user");
    try std.testing.expect(get(user, "name").eql(stringValue("Jane")));
    try std.testing.expect(get(get(user, "profile"), "bio").eql(stringValue("New bio")));
    try std.testing.expect(get(get(user, "profile"), "avatar").eql(stringValue("avatar.jpg")));

    // Verify metadata structure is preserved
    try std.testing.expect(fieldsOf(result.metadata) != .undefined);
    try std.testing.expect(get(fieldsOf(result.metadata), "user") != .undefined);
    try std.testing.expect(get(get(get(fieldsOf(result.metadata), "user"), "fields"), "profile") != .undefined);
}

//
// The records below are the ones smoke test 45 produces, read out of the real databases it leaves
// behind with `bdb shard <db>/.db/bson metadata <shard>`.
//
// A freshly added asset carries `description: ""` as a real field (upload-asset.worker.ts writes
// it on every import) with no per-field metadata of its own, so the origin's side of the
// comparison falls back to the record-level timestamp, which is when the HOST created the record.
// The device edits the description and stamps it with its OWN clock, and the merge compares the
// two numbers without regard for which machine produced them.
//
// The emulator runs about 22 seconds behind the host, and test 45 reaches the edit about 26
// seconds after the host writes the record, so the edit is normally stamped only about 4 seconds
// above the record. Measured on a passing run: record 1786316805276, description 1786316809381,
// a margin of 4105ms. Any run that reaches the edit a few seconds sooner, or on a device a few
// seconds further behind, stamps it at or below the record and the origin's empty string wins.
// updateMetadata guarantees the edited field is stamped above the record it changed, however far
// behind the editing device's clock is, so the merge below is the one that actually runs. Without
// that guarantee the two sides came in equal and the origin's empty string won, which is the
// failure this pair of tests exists to keep out.
//
const HOST_RECORD_TIMESTAMP = 1786316805276;

test "an edit stamped above the record beats an untouched empty field on the other side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The replica on the device. Replication copied the record verbatim, so the record-level
    // timestamp is still the host's, and the edit carries the stamp updateMetadata gave it.
    const deviceReplica = try record(allocator, "123", &.{property("description", stringValue("Edited on the device"))}, &.{
        property("timestamp", numberValue(HOST_RECORD_TIMESTAMP)),
        property("fields", try objectValue(allocator, &.{
            property("description", try leaf(allocator, HOST_RECORD_TIMESTAMP + 1)),
        })),
    });
    // The origin in the bucket, untouched since the host created it.
    const origin = try record(allocator, "123", &.{property("description", stringValue(""))}, &.{property("timestamp", numberValue(HOST_RECORD_TIMESTAMP))});

    // The argument order of the push leg in syncDatabases: the device replica is the source and
    // the origin is the target.
    const result = try mergeRecords(allocator, deviceReplica, origin);

    try std.testing.expect(get(.{ .document = result.fields }, "description").eql(stringValue("Edited on the device")));
}

test "an edit that beat the record keeps its stamp through the merge, so it survives the next one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // cleanupMetadata drops a field entry whose timestamp only equals the record's, which is how
    // the losing merge used to come out byte-for-byte identical to the record already stored: the
    // origin's root hash never moved and nothing looked wrong. A winning edit must come out the
    // other side still carrying its own stamp.
    const deviceReplica = try record(allocator, "123", &.{property("description", stringValue("Edited on the device"))}, &.{
        property("timestamp", numberValue(HOST_RECORD_TIMESTAMP)),
        property("fields", try objectValue(allocator, &.{
            property("description", try leaf(allocator, HOST_RECORD_TIMESTAMP + 1)),
        })),
    });
    const origin = try record(allocator, "123", &.{property("description", stringValue(""))}, &.{property("timestamp", numberValue(HOST_RECORD_TIMESTAMP))});

    const result = try mergeRecords(allocator, deviceReplica, origin);

    try std.testing.expect(get(get(fieldsOf(result.metadata), "description"), "timestamp").eql(numberValue(HOST_RECORD_TIMESTAMP + 1)));
}
