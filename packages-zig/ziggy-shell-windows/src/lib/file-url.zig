//
// Building the file URL of a directory.
//

const std = @import("std");

//
// Returns the file URL, ending in a slash, of the directory at the given absolute Windows path, such as
// "file:///C:/Users/me/app/ui/" for "C:\Users\me\app\ui". Backslashes become slashes and every byte other than a letter,
// a digit, "-", ".", "_", "~", "/" and the drive letter's ":" is written as %XX, so the text is already in the form the
// web view reports an address in and is not changed when the web view reads it back. The caller owns the result.
//
// A UNC path (\\server\share) is refused, because its file URL has a different layout.
//
pub fn directoryFileUrl(allocator: std.mem.Allocator, windows_path: []const u8) ![:0]u8 {
    if (windows_path.len < 3 or !std.ascii.isAlphabetic(windows_path[0]) or windows_path[1] != ':' or (windows_path[2] != '\\' and windows_path[2] != '/')) {
        return error.PathIsNotDriveAbsolute;
    }
    var url: std.ArrayList(u8) = .empty;
    errdefer url.deinit(allocator);
    try url.appendSlice(allocator, "file:///");
    for (windows_path, 0..) |byte, index| {
        if (index == 1 and byte == ':') {
            try url.append(allocator, byte);
        }
        else if (byte == '\\') {
            try url.append(allocator, '/');
        }
        else if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '/') {
            try url.append(allocator, byte);
        }
        else {
            try url.print(allocator, "%{X:0>2}", .{byte});
        }
    }
    if (url.items[url.items.len - 1] != '/') {
        try url.append(allocator, '/');
    }
    return url.toOwnedSliceSentinel(allocator, 0);
}
