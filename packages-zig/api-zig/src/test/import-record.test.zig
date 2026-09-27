const std = @import("std");
const api_zig = @import("api-zig");
const import_record = api_zig.import_record;
const IImportRecord = import_record.IImportRecord;
const IImportRecordEntry = import_record.IImportRecordEntry;
const ImportSource = import_record.ImportSource;
const MAX_IMPORT_RECORD_ENTRIES = import_record.MAX_IMPORT_RECORD_ENTRIES;
const addImportEntries = import_record.addImportEntries;
const createImportRecord = import_record.createImportRecord;
const parseImportRecord = import_record.parseImportRecord;
const serializeImportRecord = import_record.serializeImportRecord;

//
// One import, with everything filled in.
//
fn makeEntry(allocator: std.mem.Allocator, logicalPath: []const u8, source: ImportSource) !IImportRecordEntry {
    return .{
        .assetId = try std.fmt.allocPrint(allocator, "asset-{s}", .{logicalPath}),
        .logicalPath = logicalPath,
        .outcome = .imported,
        .importedAt = "2026-01-01T00:00:00.000Z",
        .source = source,
        .micro = "abc",
    };
}

//
// Makes `count` manual entries named file-0, file-1 and so on.
//
fn makeEntries(allocator: std.mem.Allocator, count: usize) ![]const IImportRecordEntry {
    const entries = try allocator.alloc(IImportRecordEntry, count);
    for (entries, 0..) |*entry, index| {
        entry.* = try makeEntry(allocator, try std.fmt.allocPrint(allocator, "file-{d}", .{index}), .manual);
    }
    return entries;
}

//
// Asserts that the logical paths of the entries are the expected ones, in order.
//
fn expectLogicalPaths(expected: []const []const u8, entries: []const IImportRecordEntry) !void {
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |expectedPath, entry| {
        try std.testing.expectEqualStrings(expectedPath, entry.logicalPath);
    }
}

//
// Asserts that two optional strings are equal.
//
fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expectedText| {
        try std.testing.expectEqualStrings(expectedText, actual.?);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Asserts that two records are equal (TypeScript: `toEqual`).
//
fn expectRecord(expected: IImportRecord, actual: IImportRecord) !void {
    try std.testing.expectEqual(expected.truncated, actual.truncated);
    try std.testing.expectEqual(expected.entries.len, actual.entries.len);
    for (expected.entries, actual.entries) |expectedEntry, actualEntry| {
        try std.testing.expectEqualStrings(expectedEntry.assetId, actualEntry.assetId);
        try std.testing.expectEqualStrings(expectedEntry.logicalPath, actualEntry.logicalPath);
        try std.testing.expectEqual(expectedEntry.outcome, actualEntry.outcome);
        try std.testing.expectEqualStrings(expectedEntry.importedAt, actualEntry.importedAt);
        try std.testing.expectEqual(expectedEntry.source, actualEntry.source);
        try expectOptionalString(expectedEntry.micro, actualEntry.micro);
    }
}

test "a new record has nothing in it and nothing dropped" {
    const record = createImportRecord();

    try std.testing.expectEqual(@as(usize, 0), record.entries.len);
    try std.testing.expectEqual(false, record.truncated);
}

test "imports are kept newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // They arrive oldest first, in the order they happened, and are shown the other way round.
    const record = try addImportEntries(allocator, createImportRecord(), &.{ try makeEntry(allocator, "one", .manual), try makeEntry(allocator, "two", .manual) });

    try expectLogicalPaths(&.{ "two", "one" }, record.entries);
}

test "a later import goes above an earlier one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try addImportEntries(allocator, createImportRecord(), &.{try makeEntry(allocator, "one", .manual)});
    const second = try addImportEntries(allocator, first, &.{try makeEntry(allocator, "two", .manual)});

    try expectLogicalPaths(&.{ "two", "one" }, second.entries);
}

test "manual and automatic imports go into the same list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record = try addImportEntries(allocator, createImportRecord(), &.{
        try makeEntry(allocator, "asked-for", .manual),
        try makeEntry(allocator, "arrived", .automatic),
    });

    try std.testing.expectEqual(@as(usize, 2), record.entries.len);
    try std.testing.expectEqual(ImportSource.automatic, record.entries[0].source);
    try std.testing.expectEqual(ImportSource.manual, record.entries[1].source);
}

test "adding nothing leaves the record alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = try addImportEntries(allocator, createImportRecord(), &.{try makeEntry(allocator, "one", .manual)});
    const after = try addImportEntries(allocator, before, &.{});

    // (TypeScript: `toBe`, the same object; Zig: the same entries.)
    try std.testing.expectEqual(before.entries.ptr, after.entries.ptr);
    try std.testing.expectEqual(before.entries.len, after.entries.len);
    try std.testing.expectEqual(before.truncated, after.truncated);
}

test "nothing is dropped until the cap is reached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = try makeEntries(allocator, MAX_IMPORT_RECORD_ENTRIES);

    const record = try addImportEntries(allocator, createImportRecord(), entries);

    try std.testing.expectEqual(@as(usize, MAX_IMPORT_RECORD_ENTRIES), record.entries.len);
    try std.testing.expectEqual(false, record.truncated);
}

test "past the cap the oldest go, and the record says so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = try makeEntries(allocator, MAX_IMPORT_RECORD_ENTRIES + 1);

    const record = try addImportEntries(allocator, createImportRecord(), entries);

    try std.testing.expectEqual(@as(usize, MAX_IMPORT_RECORD_ENTRIES), record.entries.len);

    // The newest survives and the oldest is the one that went.
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "file-{d}", .{MAX_IMPORT_RECORD_ENTRIES}), record.entries[0].logicalPath);
    for (record.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.logicalPath, "file-0"));
    }

    // Saying so matters: a list that silently stops is read as the whole history.
    try std.testing.expectEqual(true, record.truncated);
}

test "once something has been dropped the record stays truncated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const full = try addImportEntries(allocator, createImportRecord(), try makeEntries(allocator, MAX_IMPORT_RECORD_ENTRIES + 1));

    const later = try addImportEntries(allocator, full, &.{try makeEntry(allocator, "newest", .manual)});

    // The hole in the history does not heal by adding more.
    try std.testing.expectEqual(true, later.truncated);
}

test "adding does not change the record it was given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const before = try addImportEntries(allocator, createImportRecord(), &.{try makeEntry(allocator, "one", .manual)});

    _ = try addImportEntries(allocator, before, &.{try makeEntry(allocator, "two", .manual)});

    try expectLogicalPaths(&.{"one"}, before.entries);
}

test "a record survives being written and read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record = try addImportEntries(allocator, createImportRecord(), &.{ try makeEntry(allocator, "one", .manual), try makeEntry(allocator, "two", .automatic) });

    const readBack = try parseImportRecord(allocator, try serializeImportRecord(allocator, record));

    try expectRecord(record, readBack);
}

test "a file that is not a record reads as empty rather than throwing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqual(@as(usize, 0), (try parseImportRecord(allocator, "not json at all")).entries.len);
    try std.testing.expectEqual(@as(usize, 0), (try parseImportRecord(allocator, "[]")).entries.len);
    try std.testing.expectEqual(@as(usize, 0), (try parseImportRecord(allocator, "null")).entries.len);
    try std.testing.expectEqual(@as(usize, 0), (try parseImportRecord(allocator, "{}")).entries.len);
}

test "entries that are not imports are dropped rather than shown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const contents =
        \\{"entries":[{"assetId":"asset-good","logicalPath":"good","outcome":"imported","importedAt":"2026-01-01T00:00:00.000Z","source":"manual","micro":"abc"},{"logicalPath":"no outcome","source":"manual"},{"outcome":"imported","source":"manual"},{"logicalPath":"bad source","outcome":"imported","source":"somewhere"},null,"not an object"],"truncated":false}
    ;

    const record = try parseImportRecord(allocator, contents);

    try expectLogicalPaths(&.{"good"}, record.entries);
}

test "a stored record longer than the cap is trimmed and marked truncated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const contents = try serializeImportRecord(allocator, .{
        .entries = try makeEntries(allocator, MAX_IMPORT_RECORD_ENTRIES + 5),
        .truncated = false,
    });

    const record = try parseImportRecord(allocator, contents);

    try std.testing.expectEqual(@as(usize, MAX_IMPORT_RECORD_ENTRIES), record.entries.len);
    try std.testing.expectEqual(true, record.truncated);
}

//
// The stored form is what JSON.stringify writes, so a record written by one CLI reads in the other.
// (No TypeScript counterpart: TypeScript's serializeImportRecord is JSON.stringify itself.)
//
test "a record is stored as JSON.stringify writes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const record = try addImportEntries(allocator, createImportRecord(), &.{
        try makeEntry(allocator, "one", .manual),
        .{
            .assetId = "",
            .logicalPath = "two",
            .outcome = .failed,
            .importedAt = "2026-01-01T00:00:00.000Z",
            .source = .automatic,
        },
    });

    try std.testing.expectEqualStrings(
        "{\"entries\":[{\"assetId\":\"\",\"logicalPath\":\"two\",\"outcome\":\"failed\",\"importedAt\":\"2026-01-01T00:00:00.000Z\",\"source\":\"automatic\"},{\"assetId\":\"asset-one\",\"logicalPath\":\"one\",\"outcome\":\"imported\",\"importedAt\":\"2026-01-01T00:00:00.000Z\",\"source\":\"manual\",\"micro\":\"abc\"}],\"truncated\":false}",
        try serializeImportRecord(allocator, record),
    );
}
