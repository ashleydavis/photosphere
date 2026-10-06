const std = @import("std");
const ziggy = @import("ziggy-core");

const DroppedFiles = ziggy.dropped_files.DroppedFiles;

//
// Writes a file with the given text into the directory and returns its full path, allocated with the testing allocator.
//
fn writeFile(directory: std.testing.TmpDir, name: []const u8, text: []const u8) ![]u8 {
    try directory.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = text,
    });
    const directory_path = try directory.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    return try std.fs.path.join(std.testing.allocator, &.{ directory_path, name });
}

//
// The JSON text of an array holding the one path, allocated with the testing allocator.
//
fn arrayOf(path: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(std.testing.allocator, &[_][]const u8{path}, .{});
}

test "the paths of a drop come back as a JSON array, in the order dropped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try writeFile(tmp, "photo one.jpg", "12345");
    defer std.testing.allocator.free(first);
    try tmp.dir.createDir(std.testing.io, "a folder", .default_dir);
    const directory_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory_path);
    const folder = try std.fs.path.join(std.testing.allocator, &.{ directory_path, "a folder" });
    defer std.testing.allocator.free(folder);
    var dropped = DroppedFiles.init(std.testing.allocator);
    defer dropped.deinit();
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, &[_][]const u8{ first, folder }, .{});
    defer std.testing.allocator.free(json);
    try dropped.replace(std.testing.io, json);
    const paths = try dropped.pathsJson(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings(json, paths);
}

test "nothing dropped gives an empty array" {
    var dropped = DroppedFiles.init(std.testing.allocator);
    defer dropped.deinit();
    const paths = try dropped.pathsJson(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings("[]", paths);
}

test "a new drop replaces the last one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try writeFile(tmp, "first.txt", "1");
    defer std.testing.allocator.free(first);
    const second = try writeFile(tmp, "second.txt", "22");
    defer std.testing.allocator.free(second);
    var dropped = DroppedFiles.init(std.testing.allocator);
    defer dropped.deinit();
    const first_json = try arrayOf(first);
    defer std.testing.allocator.free(first_json);
    const second_json = try arrayOf(second);
    defer std.testing.allocator.free(second_json);
    try dropped.replace(std.testing.io, first_json);
    try dropped.replace(std.testing.io, second_json);
    const paths = try dropped.pathsJson(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings(second_json, paths);
}

test "a path that does not exist is an error and keeps the last drop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeFile(tmp, "keep.txt", "k");
    defer std.testing.allocator.free(path);
    var dropped = DroppedFiles.init(std.testing.allocator);
    defer dropped.deinit();
    const json = try arrayOf(path);
    defer std.testing.allocator.free(json);
    try dropped.replace(std.testing.io, json);
    try std.testing.expectError(error.FileNotFound, dropped.replace(std.testing.io, "[\"/nonexistent/nothing.txt\"]"));
    try std.testing.expectError(error.NotAnArrayOfPaths, dropped.replace(std.testing.io, "{}"));
    const paths = try dropped.pathsJson(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(paths);
    try std.testing.expectEqualStrings(json, paths);
}
