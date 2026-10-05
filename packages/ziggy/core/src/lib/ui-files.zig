//
// The app's bundled page, held in the executable on the platforms that embed it. The app's build embeds every file of
// its built page and hands the shell a list of them, and the shell answers the web view's requests from that list, so
// the page needs no files beside the executable.
//

const std = @import("std");

//
// One file of the app's bundled page.
//
pub const UiFile = struct {
    // The path inside the page, with forward slashes and no leading slash, such as "assets/main.js".
    path: []const u8,
    // The file's bytes.
    content: []const u8,
};

//
// Finds the file a request is for. The request path is the path part of the page's URL, so it starts with a slash, and
// the bare root means the page itself. The path must match a file's path exactly, so a path with ".." in it finds nothing.
//
pub fn findFile(files: []const UiFile, request_path: []const u8) ?*const UiFile {
    var path = request_path;
    if (std.mem.startsWith(u8, path, "/")) {
        path = path[1..];
    }
    if (path.len == 0) {
        path = "index.html";
    }
    for (files) |*file| {
        if (std.mem.eql(u8, file.path, path)) {
            return file;
        }
    }
    return null;
}

//
// The content type to send for a file, by its extension. A file with an extension that is not known is sent as plain
// bytes, which a web view will not run or show.
//
pub fn contentType(path: []const u8) [:0]const u8 {
    const extension = std.fs.path.extension(path);
    const known = [_]struct {
        extension: []const u8,
        content_type: [:0]const u8,
    }{
        .{ .extension = ".html", .content_type = "text/html; charset=utf-8" },
        .{ .extension = ".js", .content_type = "text/javascript; charset=utf-8" },
        .{ .extension = ".mjs", .content_type = "text/javascript; charset=utf-8" },
        .{ .extension = ".css", .content_type = "text/css; charset=utf-8" },
        .{ .extension = ".json", .content_type = "application/json" },
        .{ .extension = ".map", .content_type = "application/json" },
        .{ .extension = ".txt", .content_type = "text/plain; charset=utf-8" },
        .{ .extension = ".svg", .content_type = "image/svg+xml" },
        .{ .extension = ".png", .content_type = "image/png" },
        .{ .extension = ".jpg", .content_type = "image/jpeg" },
        .{ .extension = ".jpeg", .content_type = "image/jpeg" },
        .{ .extension = ".gif", .content_type = "image/gif" },
        .{ .extension = ".webp", .content_type = "image/webp" },
        .{ .extension = ".ico", .content_type = "image/x-icon" },
        .{ .extension = ".woff", .content_type = "font/woff" },
        .{ .extension = ".woff2", .content_type = "font/woff2" },
        .{ .extension = ".wasm", .content_type = "application/wasm" },
    };
    for (known) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry.extension)) {
            return entry.content_type;
        }
    }
    return "application/octet-stream";
}
