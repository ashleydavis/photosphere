const std = @import("std");
const file_url = @import("../lib/file-url.zig");

test "a plain path becomes a file URL ending in a slash" {
    const url = try file_url.directoryFileUrl(std.testing.allocator, "C:\\Users\\me\\app\\ui");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///C:/Users/me/app/ui/", url);
}

test "spaces and other bytes are percent encoded" {
    const url = try file_url.directoryFileUrl(std.testing.allocator, "C:\\Program Files\\My App (x86)\\ui");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///C:/Program%20Files/My%20App%20%28x86%29/ui/", url);
}

test "non ASCII bytes are percent encoded one byte at a time" {
    const url = try file_url.directoryFileUrl(std.testing.allocator, "D:\\r\xc3\xa9sum\xc3\xa9\\ui");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///D:/r%C3%A9sum%C3%A9/ui/", url);
}

test "a path already ending in a separator gets one slash" {
    const url = try file_url.directoryFileUrl(std.testing.allocator, "C:\\app\\ui\\");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///C:/app/ui/", url);
}

test "UNC and relative paths are refused" {
    try std.testing.expectError(error.PathIsNotDriveAbsolute, file_url.directoryFileUrl(std.testing.allocator, "\\\\server\\share\\ui"));
    try std.testing.expectError(error.PathIsNotDriveAbsolute, file_url.directoryFileUrl(std.testing.allocator, "ui"));
}
