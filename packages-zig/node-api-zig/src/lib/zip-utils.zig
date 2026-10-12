//
// Utility functions for extracting files from zip files
// (Zig: there are no Node streams, so each function returns the whole contents of the file it extracts, allocated with
// the allocator, where the TypeScript returns `nodeStream()` of the entry. The zip is read with the port of JSZip under
// third-party/jszip, which is what the TypeScript reads it with.)
//

const std = @import("std");
const utils = @import("utils-zig");
const jszip = @import("third-party/jszip/index.zig");
const errors = utils.errors;
const JSZip = jszip.JSZip;

//
// Extracts a file from a zip file and returns its contents.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip
// (Zig: the zip is loaded into an arena of its own, which is freed once the contents are copied out with the allocator.)
//
pub fn extractFileFromZip(allocator: std.mem.Allocator, io: std.Io, zipFilePath: []const u8, filePath: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var zip = JSZip.init(arena.allocator());
    const zipData = try std.Io.Dir.cwd().readFileAlloc(io, zipFilePath, arena.allocator(), .unlimited);
    const unpacked = try zip.loadAsync(zipData);

    const zipObject = unpacked.files.get(filePath);
    if (zipObject == null or zipObject.?.dir) {
        return errors.throwError("File \"{s}\" not found in zip \"{s}\"", .{ filePath, zipFilePath });
    }

    return allocator.dupe(u8, try zipObject.?.asyncNodeBuffer(arena.allocator()));
}

//
// Extracts a nested zip file from a parent zip and returns its contents.
// This handles the case where a zip file contains another zip file.
// (Zig: the zip is loaded into an arena of its own, which is freed once the contents are copied out with the allocator.)
//
pub fn extractNestedZipFromParent(allocator: std.mem.Allocator, io: std.Io, parentZipFilePath: []const u8, nestedZipRelativePath: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parentZip = JSZip.init(arena.allocator());
    const parentData = try std.Io.Dir.cwd().readFileAlloc(io, parentZipFilePath, arena.allocator(), .unlimited);
    const unpacked = try parentZip.loadAsync(parentData);
    const nestedZipObject = unpacked.files.get(nestedZipRelativePath);
    if (nestedZipObject == null or nestedZipObject.?.dir) {
        return errors.throwError("Nested zip file \"{s}\" not found in parent zip \"{s}\"", .{ nestedZipRelativePath, parentZipFilePath });
    }
    return allocator.dupe(u8, try nestedZipObject.?.asyncNodeBuffer(arena.allocator()));
}

//
// Extracts a file from a zip (possibly nested) and returns its contents.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip (may include nested zip paths like "nested.zip/file.jpg")
//
pub fn extractFileFromZipRecursive(allocator: std.mem.Allocator, io: std.Io, zipFilePath: []const u8, filePath: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Check if filePath indicates a nested zip (contains a .zip in the path)
    var pathParts: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitAny(u8, filePath, "/\\");
    while (parts.next()) |part| {
        try pathParts.append(arena.allocator(), part);
    }
    const lastPart = pathParts.items[pathParts.items.len - 1];
    var zipIndex: ?usize = null;
    for (pathParts.items, 0..) |part, partIndex| {
        if (std.mem.endsWith(u8, part, ".zip") and !std.mem.eql(u8, part, lastPart)) {
            zipIndex = partIndex;
            break;
        }
    }

    if (zipIndex) |foundIndex| {
        // File is in a nested zip
        const nestedZipPath = try std.mem.join(arena.allocator(), "/", pathParts.items[0 .. foundIndex + 1]);
        const fileInNestedZip = try std.mem.join(arena.allocator(), "/", pathParts.items[foundIndex + 1 ..]);

        // Extract the nested zip first
        const nestedZipData = try extractNestedZipFromParent(arena.allocator(), io, zipFilePath, nestedZipPath);

        // Load the nested zip and extract the file
        var nestedZip = JSZip.init(arena.allocator());
        const nestedUnpacked = try nestedZip.loadAsync(nestedZipData);
        const fileObject = nestedUnpacked.files.get(fileInNestedZip);
        if (fileObject == null or fileObject.?.dir) {
            return errors.throwError("File \"{s}\" not found in nested zip \"{s}\" within \"{s}\"", .{ fileInNestedZip, nestedZipPath, zipFilePath });
        }
        return allocator.dupe(u8, try fileObject.?.asyncNodeBuffer(arena.allocator()));
    }
    else {
        // File is directly in the zip
        return extractFileFromZip(allocator, io, zipFilePath, filePath);
    }
}
