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
