const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const zip = std.zip;
const flate = std.compress.flate;

//
// Utility functions for extracting files from zip files
// (Zig: there are no Node streams, so each function returns the whole contents of the file it extracts, allocated with the allocator.)
//

//
// Finds an entry of a zip held in memory and returns its contents, or null when the zip has no such entry or the entry is a directory.
// (A name is matched exactly, as it is written in the zip.)
//
fn readEntry(allocator: std.mem.Allocator, zipBytes: []const u8, entryPath: []const u8) !?[]u8 {
    // (Zig: the standard library's search for the end record does not compile in this version of Zig, so it is done here.)
    const endRecordStart = std.mem.lastIndexOf(u8, zipBytes, &zip.end_record_sig) orelse {
        return errors.throwError("The data is not a zip file", .{});
    };
    var endRecordReader = std.Io.Reader.fixed(zipBytes[endRecordStart..]);
    const endRecord = endRecordReader.takeStruct(zip.EndRecord, .little) catch {
        return errors.throwError("The data is not a zip file", .{});
    };
    if (endRecord.need_zip64()) {
        return errors.throwError("A zip file with 64 bit sizes is not supported", .{});
    }

    var offset: usize = endRecord.central_directory_offset;
    var index: usize = 0;
    while (index < endRecord.record_count_total) : (index += 1) {
        if (offset > zipBytes.len) {
            return errors.throwError("The data is not a zip file", .{});
        }
        var headerReader = std.Io.Reader.fixed(zipBytes[offset..]);
        const header = headerReader.takeStruct(zip.CentralDirectoryFileHeader, .little) catch {
            return errors.throwError("The data is not a zip file", .{});
        };
        if (!std.mem.eql(u8, &header.signature, &zip.central_file_header_sig)) {
            return errors.throwError("The data is not a zip file", .{});
        }
        const nameStart = offset + @sizeOf(zip.CentralDirectoryFileHeader);
        if (nameStart + header.filename_len > zipBytes.len) {
            return errors.throwError("The data is not a zip file", .{});
        }
        const name = zipBytes[nameStart .. nameStart + header.filename_len];
        offset = nameStart + header.filename_len + header.extra_len + header.comment_len;
        if (!std.mem.eql(u8, name, entryPath)) {
            continue;
        }
        if (name.len > 0 and name[name.len - 1] == '/') {
            return null;
        }
        return try readEntryData(allocator, zipBytes, header);
    }
    return null;
}

//
// Reads the contents of the entry a central directory header describes.
//
fn readEntryData(allocator: std.mem.Allocator, zipBytes: []const u8, header: zip.CentralDirectoryFileHeader) ![]u8 {
    if (header.flags.encrypted) {
        return errors.throwError("An encrypted zip file is not supported", .{});
    }
    var localReader = std.Io.Reader.fixed(zipBytes[@min(header.local_file_header_offset, zipBytes.len)..]);
    const local = localReader.takeStruct(zip.LocalFileHeader, .little) catch {
        return errors.throwError("The data is not a zip file", .{});
    };
    if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig)) {
        return errors.throwError("The data is not a zip file", .{});
    }
    const dataStart = @as(usize, header.local_file_header_offset) + @sizeOf(zip.LocalFileHeader) + local.filename_len + local.extra_len;
    const dataEnd = dataStart + header.compressed_size;
    if (dataEnd > zipBytes.len) {
        return errors.throwError("The data is not a zip file", .{});
    }
    const data = zipBytes[dataStart..dataEnd];

    switch (header.compression_method) {
        .store => return try allocator.dupe(u8, data),
        .deflate => {
            var input = std.Io.Reader.fixed(data);
            var window: [flate.max_window_len]u8 = undefined;
            var decompress: flate.Decompress = .init(&input, .raw, &window);
            return decompress.reader.readAlloc(allocator, header.uncompressed_size) catch {
                return errors.throwError("A file in the zip file could not be decompressed", .{});
            };
        },
        else => return errors.throwError("The zip file uses a compression method that is not supported", .{}),
    }
}

//
// Extracts a file from a zip file and returns its contents.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip
//
pub fn extractFileFromZip(allocator: std.mem.Allocator, io: std.Io, zipFilePath: []const u8, filePath: []const u8) ![]u8 {
    const zipData = try std.Io.Dir.cwd().readFileAlloc(io, zipFilePath, allocator, .unlimited);
    defer allocator.free(zipData);
    return try readEntry(allocator, zipData, filePath) orelse {
        return errors.throwError("File \"{s}\" not found in zip \"{s}\"", .{ filePath, zipFilePath });
    };
}

//
// Extracts a nested zip file from a parent zip and returns its contents.
// This handles the case where a zip file contains another zip file.
//
pub fn extractNestedZipFromParent(allocator: std.mem.Allocator, io: std.Io, parentZipFilePath: []const u8, nestedZipRelativePath: []const u8) ![]u8 {
    const parentData = try std.Io.Dir.cwd().readFileAlloc(io, parentZipFilePath, allocator, .unlimited);
    defer allocator.free(parentData);
    return try readEntry(allocator, parentData, nestedZipRelativePath) orelse {
        return errors.throwError("Nested zip file \"{s}\" not found in parent zip \"{s}\"", .{ nestedZipRelativePath, parentZipFilePath });
    };
}

//
// Extracts a file from a zip (possibly nested) and returns its contents.
// zipFilePath: Path to the zip file on the filesystem
// filePath: Relative path of the file within the zip (may include nested zip paths like "nested.zip/file.jpg")
//
pub fn extractFileFromZipRecursive(allocator: std.mem.Allocator, io: std.Io, zipFilePath: []const u8, filePath: []const u8) ![]u8 {
    // Check if filePath indicates a nested zip (contains a .zip in the path)
    var pathParts: std.ArrayList([]const u8) = .empty;
    defer pathParts.deinit(allocator);
    var parts = std.mem.splitAny(u8, filePath, "/\\");
    while (parts.next()) |part| {
        try pathParts.append(allocator, part);
    }
    const lastPart = pathParts.items[pathParts.items.len - 1];
    var zipIndex: ?usize = null;
    for (pathParts.items, 0..) |part, partIndex| {
        if (std.mem.endsWith(u8, part, ".zip") and !std.mem.eql(u8, part, lastPart)) {
            zipIndex = partIndex;
            break;
        }
    }

    const foundIndex = zipIndex orelse {
        // File is directly in the zip
        return try extractFileFromZip(allocator, io, zipFilePath, filePath);
    };

    // File is in a nested zip
    const nestedZipPath = try std.mem.join(allocator, "/", pathParts.items[0 .. foundIndex + 1]);
    defer allocator.free(nestedZipPath);
    const fileInNestedZip = try std.mem.join(allocator, "/", pathParts.items[foundIndex + 1 ..]);
    defer allocator.free(fileInNestedZip);

    // Extract the nested zip first
    const nestedZipData = try extractNestedZipFromParent(allocator, io, zipFilePath, nestedZipPath);
    defer allocator.free(nestedZipData);

    // Load the nested zip and extract the file
    return try readEntry(allocator, nestedZipData, fileInNestedZip) orelse {
        return errors.throwError("File \"{s}\" not found in nested zip \"{s}\" within \"{s}\"", .{ fileInNestedZip, nestedZipPath, zipFilePath });
    };
}
