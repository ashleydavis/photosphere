const std = @import("std");
const ui_files = @import("ziggy-core").ui_files;

const files = [_]ui_files.UiFile{
    .{
        .path = "index.html",
        .content = "<html></html>",
    },
    .{
        .path = "assets/main.js",
        .content = "run();",
    },
};

test "a request path finds the file with that path" {
    const file = ui_files.findFile(&files, "/assets/main.js").?;
    try std.testing.expectEqualStrings("run();", file.content);
}

test "the bare root finds the page" {
    const file = ui_files.findFile(&files, "/").?;
    try std.testing.expectEqualStrings("index.html", file.path);
    try std.testing.expectEqualStrings("index.html", ui_files.findFile(&files, "").?.path);
}

test "a path that is not a file finds nothing" {
    try std.testing.expect(ui_files.findFile(&files, "/missing.js") == null);
    try std.testing.expect(ui_files.findFile(&files, "/assets/") == null);
}

test "a path that climbs out of the page finds nothing" {
    try std.testing.expect(ui_files.findFile(&files, "/assets/../index.html") == null);
    try std.testing.expect(ui_files.findFile(&files, "/../etc/passwd") == null);
}

test "a known extension gets its content type, whatever its case" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", ui_files.contentType("index.html"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", ui_files.contentType("assets/main.js"));
    try std.testing.expectEqualStrings("image/png", ui_files.contentType("logo.PNG"));
}

test "an unknown or missing extension is plain bytes" {
    try std.testing.expectEqualStrings("application/octet-stream", ui_files.contentType("data.xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", ui_files.contentType("LICENSE"));
}
