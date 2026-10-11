//
// Tests for zip-utils.zig.
//
// The zip files are built by hand in memory and written to a folder that belongs to the test, so each test reads a real file from disk
// the way the functions do in the app.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const errors = utils.errors;
const zip_utils = node_api.zip_utils;
const io = std.testing.io;

//
// One entry of a zip file to build.
//
const IEntry = struct {
    // The name of the entry as written in the zip. A name that ends with a slash is a directory.
    name: []const u8,

    // The bytes of the entry as they are held in the zip: the file itself when it is stored, a deflate stream when it is deflated.
    stored: []const u8,

    // The size of the file once it is decompressed.
    uncompressedSize: u32,

    // The compression method: 0 for stored, 8 for deflated.
    method: u16,
};

//
// A stored entry.
//
fn storedEntry(name: []const u8, data: []const u8) IEntry {
    return .{
        .name = name,
        .stored = data,
        .uncompressedSize = @intCast(data.len),
        .method = 0,
    };
}

//
// Builds a zip file holding the entries, allocated with the allocator.
//
fn buildZip(allocator: std.mem.Allocator, entries: []const IEntry) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    const offsets = try allocator.alloc(u32, entries.len);
    for (entries, offsets) |entry, *offset| {
        offset.* = @intCast(bytes.items.len);
        const checksum = std.hash.Crc32.hash(entry.stored);
        try bytes.appendSlice(allocator, "PK\x03\x04");
        try appendInt(allocator, &bytes, u16, 20);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, entry.method);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u32, checksum);
        try appendInt(allocator, &bytes, u32, @intCast(entry.stored.len));
        try appendInt(allocator, &bytes, u32, entry.uncompressedSize);
        try appendInt(allocator, &bytes, u16, @intCast(entry.name.len));
        try appendInt(allocator, &bytes, u16, 0);
        try bytes.appendSlice(allocator, entry.name);
        try bytes.appendSlice(allocator, entry.stored);
    }
    const directoryStart: u32 = @intCast(bytes.items.len);
    for (entries, offsets) |entry, offset| {
        const checksum = std.hash.Crc32.hash(entry.stored);
        try bytes.appendSlice(allocator, "PK\x01\x02");
        try appendInt(allocator, &bytes, u16, 20);
        try appendInt(allocator, &bytes, u16, 20);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, entry.method);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u32, checksum);
        try appendInt(allocator, &bytes, u32, @intCast(entry.stored.len));
        try appendInt(allocator, &bytes, u32, entry.uncompressedSize);
        try appendInt(allocator, &bytes, u16, @intCast(entry.name.len));
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u16, 0);
        try appendInt(allocator, &bytes, u32, 0);
        try appendInt(allocator, &bytes, u32, offset);
        try bytes.appendSlice(allocator, entry.name);
    }
    const directorySize: u32 = @as(u32, @intCast(bytes.items.len)) - directoryStart;
    try bytes.appendSlice(allocator, "PK\x05\x06");
    try appendInt(allocator, &bytes, u16, 0);
    try appendInt(allocator, &bytes, u16, 0);
    try appendInt(allocator, &bytes, u16, @intCast(entries.len));
    try appendInt(allocator, &bytes, u16, @intCast(entries.len));
    try appendInt(allocator, &bytes, u32, directorySize);
    try appendInt(allocator, &bytes, u32, directoryStart);
    try appendInt(allocator, &bytes, u16, 0);
    return bytes.items;
}

//
// Appends an integer to the bytes, least significant byte first, as a zip file holds them.
//
fn appendInt(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), comptime Int: type, value: Int) !void {
    var buffer: [@sizeOf(Int)]u8 = undefined;
    std.mem.writeInt(Int, &buffer, value, .little);
    try bytes.appendSlice(allocator, &buffer);
}

//
// A folder that belongs to the test, with the zip files the test wrote to it.
//
const Sandbox = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The absolute path of the folder.
    directory: []const u8,

    //
    // Makes the folder in place.
    //
    fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.directory = try temp_dirs.makeTempDir(self.arena.allocator(), io, "zip-utils");
    }

    //
    // Removes the folder and frees what the test made.
    //
    fn deinit(self: *Sandbox) void {
        temp_dirs.removeTempDir(io, self.directory);
        self.arena.deinit();
    }

    //
    // Gets the allocator of the test.
    //
    fn allocator(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Writes a zip file with the entries into the folder and returns its path.
    //
    fn writeZip(self: *Sandbox, name: []const u8, entries: []const IEntry) ![]const u8 {
        const path = try std.fs.path.join(self.allocator(), &.{ self.directory, name });
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = try buildZip(self.allocator(), entries),
        });
        return path;
    }
};

//
// Expects the call to fail with this message.
//
fn expectThrown(expectedMessage: []const u8, result: anytype) !void {
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

test "extractFileFromZip returns the contents of a stored file" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try sandbox.writeZip("photos.zip", &.{
        storedEntry("a.txt", "first"),
        storedEntry("folder/b.txt", "second"),
    });

    const contents = try zip_utils.extractFileFromZip(sandbox.allocator(), io, path, "folder/b.txt");

    try std.testing.expectEqualStrings("second", contents);
}

test "extractFileFromZip returns the contents of a deflated file" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    // A deflate stream of one final block that is not compressed: the header byte, the length 5 and its complement, and the text.
    const path = try sandbox.writeZip("photos.zip", &.{
        .{
            .name = "hello.txt",
            .stored = "\x01\x05\x00\xfa\xffhello",
            .uncompressedSize = 5,
            .method = 8,
        },
    });

    const contents = try zip_utils.extractFileFromZip(sandbox.allocator(), io, path, "hello.txt");

    try std.testing.expectEqualStrings("hello", contents);
}

test "extractFileFromZip fails for a file the zip does not hold" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try sandbox.writeZip("photos.zip", &.{storedEntry("a.txt", "first")});

    try expectThrown(
        try std.fmt.allocPrint(sandbox.allocator(), "File \"missing.txt\" not found in zip \"{s}\"", .{path}),
        zip_utils.extractFileFromZip(sandbox.allocator(), io, path, "missing.txt"),
    );
}

test "extractFileFromZip fails for a directory" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try sandbox.writeZip("photos.zip", &.{storedEntry("folder/", "")});

    try expectThrown(
        try std.fmt.allocPrint(sandbox.allocator(), "File \"folder/\" not found in zip \"{s}\"", .{path}),
        zip_utils.extractFileFromZip(sandbox.allocator(), io, path, "folder/"),
    );
}

test "extractFileFromZip fails for data that is not a zip" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try std.fs.path.join(sandbox.allocator(), &.{ sandbox.directory, "not-a-zip.zip" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "this is not a zip file",
    });

    try expectThrown("The data is not a zip file", zip_utils.extractFileFromZip(sandbox.allocator(), io, path, "a.txt"));
}

test "extractNestedZipFromParent returns the nested zip as it is held in the parent" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const inner = try buildZip(sandbox.allocator(), &.{storedEntry("inner.txt", "inside")});
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("nested.zip", inner)});

    const contents = try zip_utils.extractNestedZipFromParent(sandbox.allocator(), io, path, "nested.zip");

    try std.testing.expectEqualSlices(u8, inner, contents);
}

test "extractNestedZipFromParent fails for a nested zip the parent does not hold" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("a.txt", "first")});

    try expectThrown(
        try std.fmt.allocPrint(sandbox.allocator(), "Nested zip file \"nested.zip\" not found in parent zip \"{s}\"", .{path}),
        zip_utils.extractNestedZipFromParent(sandbox.allocator(), io, path, "nested.zip"),
    );
}

test "extractFileFromZipRecursive returns a file that is directly in the zip" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("folder/a.txt", "first")});

    const contents = try zip_utils.extractFileFromZipRecursive(sandbox.allocator(), io, path, "folder/a.txt");

    try std.testing.expectEqualStrings("first", contents);
}

test "extractFileFromZipRecursive returns a file in a zip inside the zip" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const inner = try buildZip(sandbox.allocator(), &.{storedEntry("photos/inner.txt", "inside")});
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("takeout/nested.zip", inner)});

    const contents = try zip_utils.extractFileFromZipRecursive(sandbox.allocator(), io, path, "takeout/nested.zip/photos/inner.txt");

    try std.testing.expectEqualStrings("inside", contents);
}

test "extractFileFromZipRecursive reads a path written with backslashes" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const inner = try buildZip(sandbox.allocator(), &.{storedEntry("photos/inner.txt", "inside")});
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("takeout/nested.zip", inner)});

    const contents = try zip_utils.extractFileFromZipRecursive(sandbox.allocator(), io, path, "takeout\\nested.zip\\photos\\inner.txt");

    try std.testing.expectEqualStrings("inside", contents);
}

test "extractFileFromZipRecursive fails for a file the nested zip does not hold" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const inner = try buildZip(sandbox.allocator(), &.{storedEntry("inner.txt", "inside")});
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("nested.zip", inner)});

    try expectThrown(
        try std.fmt.allocPrint(sandbox.allocator(), "File \"missing.txt\" not found in nested zip \"nested.zip\" within \"{s}\"", .{path}),
        zip_utils.extractFileFromZipRecursive(sandbox.allocator(), io, path, "nested.zip/missing.txt"),
    );
}

test "extractFileFromZipRecursive treats a name ending in .zip as a file when it is the last part of the path" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const inner = try buildZip(sandbox.allocator(), &.{storedEntry("inner.txt", "inside")});
    const path = try sandbox.writeZip("outer.zip", &.{storedEntry("nested.zip", inner)});

    const contents = try zip_utils.extractFileFromZipRecursive(sandbox.allocator(), io, path, "nested.zip");

    try std.testing.expectEqualSlices(u8, inner, contents);
}
