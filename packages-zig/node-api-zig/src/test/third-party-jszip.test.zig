const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const zip_fixture = @import("zip-fixture.zig");
const JSZip = node_api.jszip.JSZip;
const buildZip = zip_fixture.buildZip;
const errors = utils.errors;

//
// (Zig: JSZip is an npm package with no tests in this repository; these cover the port of loadAsync and of reading
// an entry, which is what the file scanner does with a zip.)
//

test "lists the entries of a zip in the order they were stored, folders included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var zip = JSZip.init(allocator);

    const loaded = try zip.loadAsync(try buildZip(allocator, &.{
        .{
            .name = "b.png",
            .data = "second",
        },
        .{
            .name = "folder/a.png",
            .data = "first",
        },
    }));

    const names = loaded.files.names.items;
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("b.png", names[0]);
    try std.testing.expectEqualStrings("folder/", names[1]);
    try std.testing.expectEqualStrings("folder/a.png", names[2]);
    try std.testing.expectEqual(true, loaded.files.get("folder/").?.dir);
    try std.testing.expectEqual(false, loaded.files.get("b.png").?.dir);
}

test "reads the contents of a stored entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var zip = JSZip.init(allocator);

    const loaded = try zip.loadAsync(try buildZip(allocator, &.{.{
        .name = "photo.png",
        .data = "the bytes of a photo",
    }}));

    try std.testing.expectEqualStrings("the bytes of a photo", try loaded.files.get("photo.png").?.asyncNodeBuffer(allocator));
}

test "reads the date of an entry from its DOS date and time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var zip = JSZip.init(allocator);

    const loaded = try zip.loadAsync(try buildZip(allocator, &.{.{
        .name = "photo.png",
        .data = "x",
    }}));

    // The fixture stamps every entry 2020-01-01 00:00:00, which JSZip reads as UTC.
    try std.testing.expectEqual(@as(i64, 1577836800000), loaded.files.get("photo.png").?.date);
}

test "inflates the entries of a compressed zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var zip = JSZip.init(allocator);

    const loaded = try zip.loadAsync(try helpers.readFile(allocator, io, "../../test/multiple-files/test-archive.zip"));

    var filesRead: usize = 0;
    for (loaded.files.names.items) |name| {
        const entry = loaded.files.get(name).?;
        if (entry.dir) {
            continue;
        }
        const contents = try entry.asyncNodeBuffer(allocator);
        try std.testing.expect(contents.len > 0);
        filesRead += 1;
    }
    try std.testing.expect(filesRead > 0);
}

test "refuses data that is not a zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var zip = JSZip.init(arena.allocator());

    try std.testing.expectError(error.Thrown, zip.loadAsync("This is not a valid zip file"));
    try std.testing.expectEqualStrings("Can't find end of central directory : is this a zip file ? If it is, see https://stuk.github.io/jszip/documentation/howto/read_zip.html", errors.lastErrorMessage());
}

test "an empty zip has no entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var zip = JSZip.init(allocator);

    const loaded = try zip.loadAsync(try buildZip(allocator, &.{}));

    try std.testing.expectEqual(@as(usize, 0), loaded.files.names.items.len);
}

//
// One entry of a zip built byte by byte, for the parts of the format the fixture builder does not write.
//
const IRawEntry = struct {
    // The file name, as stored.
    name: []const u8,

    // The stored (possibly compressed) data.
    data: []const u8 = "",

    // The compression method.
    method: u16 = 0,

    // The uncompressed size, when it is not the length of the data.
    uncompressedSize: ?u32 = null,

    // The general purpose bit flag.
    bitFlag: u16 = 0,

    // The "version made by" field: the high byte is the platform (0 DOS, 3 unix).
    versionMadeBy: u16 = 0x0014,

    // The external file attributes.
    externalAttributes: u32 = 0,

    // The extra fields of the central directory entry.
    extra: []const u8 = "",

    // The comment of the entry.
    comment: []const u8 = "",

    // Whether the sizes and offset are stored in a ZIP64 extra field instead of the central directory entry.
    zip64Sizes: bool = false,

    // Added to the offset of the local header the central directory entry gives.
    localOffsetShift: u32 = 0,
};

//
// How a zip built byte by byte is laid out.
//
const IRawZip = struct {
    // Bytes before the zip, as in a crx file.
    prefix: []const u8 = "",

    // The comment of the zip.
    comment: []const u8 = "",

    // Whether the end of central directory defers to a ZIP64 end of central directory.
    zip64: bool = false,

    // The size the ZIP64 end of central directory record gives itself.
    zip64RecordSize: u64 = 44,

    // The number of disks the ZIP64 locator gives.
    zip64Disks: u32 = 1,

    // Whether the ZIP64 locator is written.
    zip64Locator: bool = true,

    // Whether the ZIP64 end of central directory record is written.
    zip64Record: bool = true,

    // Added to the offset of the ZIP64 record the locator gives.
    zip64LocatorOffsetShift: u64 = 0,

    // The number of records the end of central directory gives, when it is not the number of entries.
    records: ?u16 = null,

    // Added to the size of the central directory the end of central directory gives.
    centralSizeExtra: u32 = 0,
};

//
// 2020-01-01 in DOS form.
//
const RAW_DOS_DATE: u16 = ((2020 - 1980) << 9) | (1 << 5) | 1;

//
// Appends a little-endian integer.
//
fn appendInt(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime IntType: type, value: IntType) !void {
    var bytes: [@sizeOf(IntType)]u8 = undefined;
    std.mem.writeInt(IntType, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

//
// Builds a zip byte by byte (the outcomes the tests expect are those of JSZip 3.10.1 for the same bytes).
//
fn buildRawZip(allocator: std.mem.Allocator, entries: []const IRawEntry, layout: IRawZip) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try output.appendSlice(allocator, layout.prefix);
    var central: std.ArrayList(u8) = .empty;
    var length: u32 = 0;
    for (entries) |entry| {
        const size: u32 = entry.uncompressedSize orelse @intCast(entry.data.len);
        const offset = length;
        const localStart = output.items.len;
        try appendInt(allocator, &output, u32, 0x04034b50);
        try appendInt(allocator, &output, u16, 10);
        try appendInt(allocator, &output, u16, entry.bitFlag);
        try appendInt(allocator, &output, u16, entry.method);
        try appendInt(allocator, &output, u16, 0);
        try appendInt(allocator, &output, u16, RAW_DOS_DATE);
        try appendInt(allocator, &output, u32, 0);
        try appendInt(allocator, &output, u32, @intCast(entry.data.len));
        try appendInt(allocator, &output, u32, size);
        try appendInt(allocator, &output, u16, @intCast(entry.name.len));
        try appendInt(allocator, &output, u16, 0);
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, entry.data);
        length += @intCast(output.items.len - localStart);

        var extra: std.ArrayList(u8) = .empty;
        if (entry.zip64Sizes) {
            try appendInt(allocator, &extra, u16, 1);
            try appendInt(allocator, &extra, u16, 28);
            try appendInt(allocator, &extra, u64, size);
            try appendInt(allocator, &extra, u64, entry.data.len);
            try appendInt(allocator, &extra, u64, offset + entry.localOffsetShift);
            try appendInt(allocator, &extra, u32, 0);
        }
        try extra.appendSlice(allocator, entry.extra);
        try appendInt(allocator, &central, u32, 0x02014b50);
        try appendInt(allocator, &central, u16, entry.versionMadeBy);
        try appendInt(allocator, &central, u16, 10);
        try appendInt(allocator, &central, u16, entry.bitFlag);
        try appendInt(allocator, &central, u16, entry.method);
        try appendInt(allocator, &central, u16, 0);
        try appendInt(allocator, &central, u16, RAW_DOS_DATE);
        try appendInt(allocator, &central, u32, 0);
        try appendInt(allocator, &central, u32, if (entry.zip64Sizes) 0xFFFFFFFF else @intCast(entry.data.len));
        try appendInt(allocator, &central, u32, if (entry.zip64Sizes) 0xFFFFFFFF else size);
        try appendInt(allocator, &central, u16, @intCast(entry.name.len));
        try appendInt(allocator, &central, u16, @intCast(extra.items.len));
        try appendInt(allocator, &central, u16, @intCast(entry.comment.len));
        try appendInt(allocator, &central, u16, 0);
        try appendInt(allocator, &central, u16, 0);
        try appendInt(allocator, &central, u32, entry.externalAttributes);
        try appendInt(allocator, &central, u32, if (entry.zip64Sizes) 0xFFFFFFFF else offset + entry.localOffsetShift);
        try central.appendSlice(allocator, entry.name);
        try central.appendSlice(allocator, extra.items);
        try central.appendSlice(allocator, entry.comment);
    }
    const centralOffset = length;
    try output.appendSlice(allocator, central.items);
    length += @intCast(central.items.len);
    const records: u16 = layout.records orelse @intCast(entries.len);
    if (layout.zip64) {
        const recordOffset = length;
        if (layout.zip64Record) {
            try appendInt(allocator, &output, u32, 0x06064b50);
            try appendInt(allocator, &output, u64, layout.zip64RecordSize);
            try appendInt(allocator, &output, u16, 45);
            try appendInt(allocator, &output, u16, 45);
            try appendInt(allocator, &output, u32, 0);
            try appendInt(allocator, &output, u32, 0);
            try appendInt(allocator, &output, u64, records);
            try appendInt(allocator, &output, u64, records);
            try appendInt(allocator, &output, u64, central.items.len + layout.centralSizeExtra);
            try appendInt(allocator, &output, u64, centralOffset);
        }
        if (layout.zip64Locator) {
            try appendInt(allocator, &output, u32, 0x07064b50);
            try appendInt(allocator, &output, u32, 0);
            try appendInt(allocator, &output, u64, recordOffset + layout.zip64LocatorOffsetShift);
            try appendInt(allocator, &output, u32, layout.zip64Disks);
        }
        try appendInt(allocator, &output, u32, 0x06054b50);
        for (0..4) |_| {
            try appendInt(allocator, &output, u16, 0xFFFF);
        }
        try appendInt(allocator, &output, u32, 0xFFFFFFFF);
        try appendInt(allocator, &output, u32, 0xFFFFFFFF);
    }
    else {
        try appendInt(allocator, &output, u32, 0x06054b50);
        try appendInt(allocator, &output, u16, 0);
        try appendInt(allocator, &output, u16, 0);
        try appendInt(allocator, &output, u16, records);
        try appendInt(allocator, &output, u16, records);
        try appendInt(allocator, &output, u32, @as(u32, @intCast(central.items.len)) + layout.centralSizeExtra);
        try appendInt(allocator, &output, u32, centralOffset);
    }
    try appendInt(allocator, &output, u16, @intCast(layout.comment.len));
    try output.appendSlice(allocator, layout.comment);
    return output.items;
}

//
// A Unicode path (0x7075) or comment (0x6375) extra field: a version, the CRC-32 of the stored text it replaces and
// the UTF-8 text.
//
fn unicodeExtraField(allocator: std.mem.Allocator, id: u16, version: u8, crcOf: []const u8, text: []const u8) ![]const u8 {
    var field: std.ArrayList(u8) = .empty;
    try appendInt(allocator, &field, u16, id);
    try appendInt(allocator, &field, u16, @intCast(5 + text.len));
    try field.append(allocator, version);
    try appendInt(allocator, &field, u32, std.hash.Crc32.hash(crcOf));
    try field.appendSlice(allocator, text);
    return field.items;
}

//
// Loads a zip built byte by byte and returns the only entry's name.
//
fn loadOnlyName(allocator: std.mem.Allocator, entries: []const IRawEntry, layout: IRawZip) ![]const u8 {
    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, entries, layout));
    try std.testing.expectEqual(@as(usize, 1), loaded.files.names.items.len);
    return loaded.files.names.items[0];
}

//
// Loads a zip built byte by byte and returns the error message it is refused with.
//
fn loadError(allocator: std.mem.Allocator, entries: []const IRawEntry, layout: IRawZip) ![]const u8 {
    var zip = JSZip.init(allocator);
    try std.testing.expectError(error.Thrown, zip.loadAsync(try buildRawZip(allocator, entries, layout)));
    return errors.lastErrorMessage();
}

test "decodes UTF-8 names, one replacement character per maximal subpart of an ill-formed sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const name = try loadOnlyName(allocator, &.{.{
        .name = "caf\xC3\xA9 \xE0\x80 \xF0\x90\x80 \xED\xA0\x80 \xF4\x90 \xFF \xC3",
        .data = "x",
        .bitFlag = 0x0800,
        .comment = "\xFE",
    }}, .{});

    try std.testing.expectEqualStrings("caf\u{E9} \u{FFFD}\u{FFFD} \u{FFFD} \u{FFFD}\u{FFFD}\u{FFFD} \u{FFFD}\u{FFFD} \u{FFFD} \u{FFFD}", name);
}

test "decodes names without the UTF-8 flag as UTF-8 too, and the comment of the zip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("caf\u{FFFD}", try loadOnlyName(allocator, &.{.{ .name = "caf\xE9", .data = "x" }}, .{ .comment = "zip \xC3\xA9" }));
}

test "takes the name from a Unicode path extra field that is current" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("n\u{E9}w", try loadOnlyName(allocator, &.{.{ .name = "old", .data = "x", .comment = "c", .extra = try unicodeExtraField(allocator, 0x7075, 1, "old", "n\u{E9}w") }}, .{}));

    // A version other than 1, or the CRC-32 of another name, leaves the stored name.
    try std.testing.expectEqualStrings("old", try loadOnlyName(allocator, &.{.{ .name = "old", .data = "x", .extra = try unicodeExtraField(allocator, 0x7075, 2, "old", "n\u{E9}w") }}, .{}));
    try std.testing.expectEqualStrings("old", try loadOnlyName(allocator, &.{.{ .name = "old", .data = "x", .extra = try unicodeExtraField(allocator, 0x7075, 1, "other", "n\u{E9}w") }}, .{}));
}

test "reads a Unicode comment extra field, current or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const commentField = try unicodeExtraField(allocator, 0x6375, 1, "c", "\u{E7}");

    // (The comment of an entry is not part of what Photosphere reads; the entry loads either way.)
    try std.testing.expectEqualStrings("a", try loadOnlyName(allocator, &.{.{ .name = "a", .data = "x", .comment = "c", .extra = try std.mem.concat(allocator, u8, &.{ commentField, commentField }) }}, .{}));
    try std.testing.expectEqualStrings("a", try loadOnlyName(allocator, &.{.{ .name = "a", .data = "x", .comment = "c", .extra = try unicodeExtraField(allocator, 0x6375, 3, "c", "\u{E7}") }}, .{}));
    try std.testing.expectEqualStrings("a", try loadOnlyName(allocator, &.{.{ .name = "a", .data = "x", .comment = "c", .extra = try unicodeExtraField(allocator, 0x6375, 1, "d", "\u{E7}") }}, .{}));
}

test "reads a ZIP64 zip, finding its end of central directory where the locator does not point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{.{ .name = "a.txt", .data = "sixty-four", .zip64Sizes = true }}, .{ .zip64 = true }));
    try std.testing.expectEqualStrings("sixty-four", try loaded.files.get("a.txt").?.asyncNodeBuffer(allocator));

    try std.testing.expectEqualStrings("a.txt", try loadOnlyName(allocator, &.{.{ .name = "a.txt", .data = "x", .zip64Sizes = true }}, .{ .zip64 = true, .zip64LocatorOffsetShift = 3 }));
}

test "refuses ZIP64 zips that span disks or lack their ZIP64 records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries: []const IRawEntry = &.{.{ .name = "a.txt", .data = "x" }};

    try std.testing.expectEqualStrings("Multi-volumes zip are not supported", try loadError(allocator, entries, .{ .zip64 = true, .zip64Disks = 2 }));
    try std.testing.expectEqualStrings("Corrupted zip: can't find the ZIP64 end of central directory locator", try loadError(allocator, entries, .{ .zip64 = true, .zip64Locator = false }));
    try std.testing.expectEqualStrings("Corrupted zip: can't find the ZIP64 end of central directory", try loadError(allocator, entries, .{ .zip64 = true, .zip64Record = false }));

    // JSZip never advances through the extensible data of a larger record, so it reads past the end.
    try std.testing.expectEqualStrings("End of data reached (data length = 185, asked index = 1947). Corrupted zip ?", try loadError(allocator, entries, .{ .zip64 = true, .zip64RecordSize = 50 }));
}

test "reads a zip that has bytes before it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{.{ .name = "a.txt", .data = "after a prefix" }}, .{ .prefix = "Cr24 header" }));
    try std.testing.expectEqualStrings("after a prefix", try loaded.files.get("a.txt").?.asyncNodeBuffer(allocator));
}

test "refuses corrupted zips as JSZip does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries: []const IRawEntry = &.{.{ .name = "a.txt", .data = "x" }};

    try std.testing.expectEqualStrings("Corrupted zip: missing 7 bytes.", try loadError(allocator, entries, .{ .centralSizeExtra = 7 }));
    try std.testing.expectEqualStrings("Corrupted zip or bug: expected 2 records in central dir, got 0", try loadError(allocator, &.{}, .{ .records = 2 }));
    try std.testing.expectEqualStrings("Corrupted zip : compression \\x63\\x00 unknown (inner file : a.txt)", try loadError(allocator, &.{.{ .name = "a.txt", .data = "x", .method = 99 }}, .{}));
    try std.testing.expectEqualStrings("Encrypted zip are not supported", try loadError(allocator, &.{.{ .name = "a.txt", .data = "x", .bitFlag = 1 }}, .{}));
    try std.testing.expectEqualStrings("Corrupted zip or bug: unexpected signature (\\x4B\\x03\\x04\\x0A, expected \\x50\\x4B\\x03\\x04)", try loadError(allocator, &.{.{ .name = "a.txt", .data = "x", .localOffsetShift = 1 }}, .{}));
    try std.testing.expectEqualStrings("Bug or corrupted zip : didn't get enough information from the central directory (compressedSize === -1 || uncompressedSize === -1)", try loadError(allocator, &.{.{ .name = "a.txt", .data = "x", .uncompressedSize = 0xFFFFFFFF }}, .{}));

    // A zip without its end of central directory.
    const whole = try buildRawZip(allocator, entries, .{});
    var zip = JSZip.init(allocator);
    try std.testing.expectError(error.Thrown, zip.loadAsync(whole[0 .. whole.len - 22]));
    try std.testing.expectEqualStrings("Corrupted zip: can't find end of central directory", errors.lastErrorMessage());
}

test "loads the records it finds when the central directory has fewer than it says" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("a.txt", try loadOnlyName(allocator, &.{.{ .name = "a.txt", .data = "x" }}, .{ .records = 3 }));
    try std.testing.expectEqualStrings("a.txt", try loadOnlyName(allocator, &.{.{ .name = "a.txt", .data = "x" }}, .{ .records = 0 }));
}

test "reading an entry whose data does not give its size fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{
        .{ .name = "short.txt", .data = "abc", .uncompressedSize = 5 },
        .{ .name = "bad-deflate.txt", .data = "\xFF\xFF\xFF\xFF", .method = 8, .uncompressedSize = 4 },
    }, .{}));

    try std.testing.expectError(error.Thrown, loaded.files.get("short.txt").?.asyncNodeBuffer(allocator));
    try std.testing.expectEqualStrings("Bug : uncompressed data size mismatch", errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, loaded.files.get("bad-deflate.txt").?.asyncNodeBuffer(allocator));
    try std.testing.expectEqualStrings("Bug : uncompressed data size mismatch", errors.lastErrorMessage());
}

test "folders come from the DOS directory attribute, and an empty entry reads as nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{
        .{ .name = "dos", .externalAttributes = 0x10 },
        .{ .name = "dosfile", .data = "d", .externalAttributes = 0x20 },
        .{ .name = "unixfile", .data = "u", .versionMadeBy = 0x0314, .externalAttributes = 0o100644 << 16 },
        .{ .name = "empty.txt" },
    }, .{}));

    const names = loaded.files.names.items;
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("dos/", names[0]);
    try std.testing.expect(loaded.files.get("dos/").?.dir);
    try std.testing.expectEqualStrings("d", try loaded.files.get("dosfile").?.asyncNodeBuffer(allocator));
    try std.testing.expectEqualStrings("u", try loaded.files.get("unixfile").?.asyncNodeBuffer(allocator));
    try std.testing.expectEqualStrings("", try loaded.files.get("empty.txt").?.asyncNodeBuffer(allocator));

    // DOS permissions with the directory bit make a folder of an entry whose attributes also say so.
    try std.testing.expectEqualStrings("dos2/", try loadOnlyName(allocator, &.{.{ .name = "dos2", .externalAttributes = 0x30 }}, .{}));
    try std.testing.expectEqualStrings("unix/", try loadOnlyName(allocator, &.{.{ .name = "unix/", .versionMadeBy = 0x0314, .externalAttributes = 0o40755 << 16 }}, .{}));
}

test "an entry that only its unix permissions make a folder fails to load, as in JSZip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("TypeError: Cannot set properties of null (setting 'unsafeOriginalName')", try loadError(allocator, &.{.{ .name = "unix", .versionMadeBy = 0x0314, .externalAttributes = 0o40755 << 16 }}, .{}));
}

test "names that are array indexes come first, in order, and a repeated name keeps its place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{
        .{ .name = "b", .data = "1" },
        .{ .name = "10", .data = "2" },
        .{ .name = "2", .data = "3" },
        .{ .name = "b", .data = "4" },
        .{ .name = "0", .data = "5" },
        .{ .name = "01", .data = "6" },
    }, .{}));

    const names = loaded.files.names.items;
    try std.testing.expectEqual(@as(usize, 5), names.len);
    const expectedNames = [_][]const u8{ "0", "2", "10", "b", "01" };
    for (expectedNames, names) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqualStrings("4", try loaded.files.get("b").?.asyncNodeBuffer(allocator));
}

test "resolves dot segments and doubled slashes in names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var zip = JSZip.init(allocator);
    const loaded = try zip.loadAsync(try buildRawZip(allocator, &.{
        .{ .name = "a/../b.txt", .data = "1" },
        .{ .name = "./c.txt", .data = "2" },
        .{ .name = "d//e.txt", .data = "3" },
        .{ .name = "/f.txt", .data = "4" },
        .{ .name = "../../g.txt", .data = "5" },
    }, .{}));

    const names = loaded.files.names.items;
    const expectedNames = [_][]const u8{ "b.txt", "c.txt", "d/e.txt", "/f.txt", "g.txt" };
    try std.testing.expectEqual(expectedNames.len, names.len);
    for (expectedNames, names) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}
