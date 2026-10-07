const std = @import("std");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// Writes the test's databases.toml, in the settings directory the app reads (PHOTOSPHERE_CONFIG_DIR).
//
fn writeDatabasesToml(app: *TestApp, text: []const u8) !void {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "{s}/config/databases.toml", .{app.tmp_path});
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = text,
    });
}

test "get-recent-databases replies an empty array when there is no databases.toml" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("get-recent-databases", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("[]", reply);
}

test "get-recent-databases replies the entries in recents order and leaves out names with no entry" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try writeDatabasesToml(&app, "recent_database_names = [ \"beta\", \"gone\", \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");
    const reply = try app.requestOk("get-recent-databases", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("[{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"},{\"name\":\"alpha\",\"description\":\"\",\"path\":\"/a\"}]", reply);
}

test "get-last-database replies null when no database is open" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("get-last-database", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "get-last-database replies the path recorded in databases.toml" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try writeDatabasesToml(&app, "recent_database_names = []\ndatabases = []\nlast_database = \"/some/db\"\n");
    const reply = try app.requestOk("get-last-database", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("\"/some/db\"", reply);
}

test "remove-recent-database-name removes only the recent name, and replies null" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try writeDatabasesToml(&app, "recent_database_names = [ \"alpha\", \"beta\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");
    const remove_reply = try app.requestOk("remove-recent-database-name", "\"ALPHA\"");
    defer allocator.free(remove_reply);
    try std.testing.expectEqualStrings("null", remove_reply);
    const recent_reply = try app.requestOk("get-recent-databases", "null");
    defer allocator.free(recent_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"}]", recent_reply);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"alpha\",\"description\":\"\",\"path\":\"/a\"},{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"}]", list_reply);
}

test "remove-recent-database-name without a name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("remove-recent-database-name", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The database needs a name.", reply);
}

test "remove-recent-database-name logs which name was removed" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("remove-recent-database-name", "\"alpha\""));
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Recent database removed: alpha") != null);
}
