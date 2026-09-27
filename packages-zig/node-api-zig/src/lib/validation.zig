const std = @import("std");
const utils = @import("utils-zig");
const tools = @import("tools-zig");
const file_scanner = @import("file-scanner.zig");
const log = &utils.log.log;
const getFileInfo = tools.getFileInfo;
const IFileStat = file_scanner.IFileStat;

//
// Validates that a file is good before allowing it to be added to the merkle tree.
// filePath must be a path to a locally extracted file (not a zip file path).
//
pub fn validateFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: []const u8, fileStat: IFileStat) !bool {
    // Check that it's not a zero-byte file.
    if (fileStat.length == 0) {
        log.@"error"(try std.fmt.allocPrint(allocator, "Invalid file {s} - zero-byte file", .{filePath}));
        return false;
    }

    if (std.mem.eql(u8, contentType, "image/vnd.adobe.photoshop")) {
        // Not sure how to validate PSD files just yet.
        return true;
    }

    if (std.mem.startsWith(u8, contentType, "image")) {
        return try validateImage(allocator, io, filePath, contentType);
    }
    else if (std.mem.startsWith(u8, contentType, "video")) {
        return try validateVideo(allocator, io, filePath, contentType);
    }

    return true;
}

//
// Validates an image file by checking if it has valid dimensions
// filePath must be a path to a locally extracted file.
//
fn validateImage(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: []const u8) !bool {
    const fileInfo = getFileInfo(allocator, io, filePath, contentType) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Invalid image {s} - analysis failed", .{filePath}), err);
        return false;
    } orelse {
        log.@"error"(try std.fmt.allocPrint(allocator, "Invalid image {s} - failed to get file info", .{filePath}));
        return false;
    };

    if (fileInfo.dimensions.width > 0 and fileInfo.dimensions.height > 0) {
        log.verbose(try std.fmt.allocPrint(allocator, "Valid image {s} - dimensions: {d}x{d}", .{ filePath, fileInfo.dimensions.width, fileInfo.dimensions.height }));
        return true;
    }
    else {
        log.@"error"(try std.fmt.allocPrint(allocator, "Invalid image {s} - invalid dimensions: {d}x{d}", .{ filePath, fileInfo.dimensions.width, fileInfo.dimensions.height }));
        return false;
    }
}

//
// Validates a video file by checking if it has valid dimensions
// filePath must be a path to a locally extracted file.
//
fn validateVideo(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: []const u8) !bool {
    const fileInfo = getFileInfo(allocator, io, filePath, contentType) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Invalid video {s} - analysis failed", .{filePath}), err);
        return false;
    } orelse {
        log.@"error"(try std.fmt.allocPrint(allocator, "Invalid video {s} - failed to get file info", .{filePath}));
        return false;
    };

    if (fileInfo.dimensions.width > 0 and fileInfo.dimensions.height > 0) {
        log.verbose(try std.fmt.allocPrint(allocator, "Valid video {s} - dimensions: {d}x{d}", .{ filePath, fileInfo.dimensions.width, fileInfo.dimensions.height }));
        return true;
    }
    else {
        log.@"error"(try std.fmt.allocPrint(allocator, "Invalid video {s} - invalid dimensions: {d}x{d}", .{ filePath, fileInfo.dimensions.width, fileInfo.dimensions.height }));
        return false;
    }
}
