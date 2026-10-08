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

//
// Reads a file under the directory the test owns. The caller frees it.
//
fn readTestFile(app: *TestApp, relative_path: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app.tmp_path, relative_path });
    defer allocator.free(path);
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
}

test "get-databases replies an empty array when there is no databases.toml" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("get-databases", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("[]", reply);
}

test "get-databases replies every entry in the file, leaving out the fields an entry does not have" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try writeDatabasesToml(&app, "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"first\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"s3:bucket/b\"\ns3_key = \"my-s3\"\norigin = \"/elsewhere\"\n");
    const reply = try app.requestOk("get-databases", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("[{\"name\":\"alpha\",\"description\":\"first\",\"path\":\"/a\"},{\"name\":\"beta\",\"description\":\"\",\"path\":\"s3:bucket/b\",\"origin\":\"/elsewhere\",\"s3Key\":\"my-s3\"}]", reply);
}

test "add-database replies with the entry, and get-databases then lists it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const add_reply = try app.requestOk("add-database", "{\"name\":\"photos\",\"description\":\"my photos\",\"path\":\"/photos\",\"encryptionKey\":\"key-1\"}");
    defer allocator.free(add_reply);
    try std.testing.expectEqualStrings("{\"name\":\"photos\",\"description\":\"my photos\",\"path\":\"/photos\",\"encryptionKey\":\"key-1\"}", add_reply);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"photos\",\"description\":\"my photos\",\"path\":\"/photos\",\"encryptionKey\":\"key-1\"}]", list_reply);
}

test "add-database with a name that is taken, in any letter case, is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("add-database", "{\"name\":\"photos\",\"description\":\"\",\"path\":\"/photos\"}"));
    const reply = try app.requestError("add-database", "{\"name\":\"PHOTOS\",\"description\":\"\",\"path\":\"/other\"}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("A database named \"PHOTOS\" already exists.", reply);
}

test "add-database without a path is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("add-database", "{\"name\":\"photos\",\"description\":\"\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The database needs a path.", reply);
}

test "find-database replies with the entry whatever the letter case of the name" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try writeDatabasesToml(&app, "recent_database_names = []\n\n[[databases]]\nname = \"Alpha\"\ndescription = \"\"\npath = \"/a\"\n");
    const reply = try app.requestOk("find-database", "\"aLPHA\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"name\":\"Alpha\",\"description\":\"\",\"path\":\"/a\"}", reply);
}

test "find-database replies null for a name that is not there" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("find-database", "\"nothing\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "update-database replaces the entry, renames it, and keeps the recents pointing at it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try writeDatabasesToml(&app, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");
    const update_reply = try app.requestOk("update-database", "{\"originalName\":\"alpha\",\"entry\":{\"name\":\"renamed\",\"description\":\"new\",\"path\":\"/b\"}}");
    defer allocator.free(update_reply);
    try std.testing.expectEqualStrings("null", update_reply);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"renamed\",\"description\":\"new\",\"path\":\"/b\"}]", list_reply);
    const recent_reply = try app.requestOk("get-recent-databases", "null");
    defer allocator.free(recent_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"renamed\",\"description\":\"new\",\"path\":\"/b\"}]", recent_reply);
}

test "update-database for a name that is not there is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("update-database", "{\"originalName\":\"nothing\",\"entry\":{\"name\":\"x\",\"description\":\"\",\"path\":\"/x\"}}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("No database named \"nothing\" found.", reply);
}

test "update-database without an entry is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("update-database", "{\"originalName\":\"alpha\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the database entry to save.", reply);
}

test "remove-database-entry removes the entry and its recent name, and replies null" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try writeDatabasesToml(&app, "recent_database_names = [ \"alpha\", \"beta\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");
    const remove_reply = try app.requestOk("remove-database-entry", "\"ALPHA\"");
    defer allocator.free(remove_reply);
    try std.testing.expectEqualStrings("null", remove_reply);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"}]", list_reply);
    const recent_reply = try app.requestOk("get-recent-databases", "null");
    defer allocator.free(recent_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"}]", recent_reply);
}

test "remove-database-entry for a name that is not there is not an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("remove-database-entry", "\"nothing\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "set-database-origin writes the origin to the database's config.json and to its entry" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "{s}/db-one", .{app.tmp_path});
    defer allocator.free(database_path);
    // Forward slashes, because the path goes into a TOML string and a JSON request, where a Windows backslash is an
    // escape. The Windows job failed in "set-database-origin writes the origin..." with no reply to the request.
    std.mem.replaceScalar(u8, database_path, '\\', '/');
    const toml = try std.fmt.allocPrint(allocator, "recent_database_names = []\n\n[[databases]]\nname = \"one\"\ndescription = \"\"\npath = \"{s}\"\n", .{database_path});
    defer allocator.free(toml);
    try writeDatabasesToml(&app, toml);
    const request = try std.fmt.allocPrint(allocator, "{{\"databasePath\":\"{s}\",\"origin\":\"/the/origin\"}}", .{database_path});
    defer allocator.free(request);
    const reply = try app.requestOk("set-database-origin", request);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    const config_json = try readTestFile(&app, "db-one/.db/config.json");
    defer allocator.free(config_json);
    try std.testing.expect(std.mem.indexOf(u8, config_json, "\"origin\": \"/the/origin\"") != null);
    const find_reply = try app.requestOk("find-database", "\"one\"");
    defer allocator.free(find_reply);
    const expected = try std.fmt.allocPrint(allocator, "{{\"name\":\"one\",\"description\":\"\",\"path\":\"{s}\",\"origin\":\"/the/origin\"}}", .{database_path});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, find_reply);
}

test "set-database-origin without an origin clears it from config.json and from the entry, keeping other keys" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "{s}/db-two", .{app.tmp_path});
    defer allocator.free(database_path);
    // Forward slashes: see the first set-database-origin test.
    std.mem.replaceScalar(u8, database_path, '\\', '/');
    const toml = try std.fmt.allocPrint(allocator, "recent_database_names = []\n\n[[databases]]\nname = \"two\"\ndescription = \"\"\npath = \"{s}\"\norigin = \"/old\"\n", .{database_path});
    defer allocator.free(toml);
    try writeDatabasesToml(&app, toml);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.db/config.json", .{database_path});
    defer allocator.free(config_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(config_path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data = "{\"origin\":\"/old\",\"other\":\"kept\"}",
    });
    const request = try std.fmt.allocPrint(allocator, "{{\"databasePath\":\"{s}\"}}", .{database_path});
    defer allocator.free(request);
    const reply = try app.requestOk("set-database-origin", request);
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    const config_json = try readTestFile(&app, "db-two/.db/config.json");
    defer allocator.free(config_json);
    try std.testing.expect(std.mem.indexOf(u8, config_json, "origin") == null);
    try std.testing.expect(std.mem.indexOf(u8, config_json, "\"other\": \"kept\"") != null);
    const find_reply = try app.requestOk("find-database", "\"two\"");
    defer allocator.free(find_reply);
    const expected = try std.fmt.allocPrint(allocator, "{{\"name\":\"two\",\"description\":\"\",\"path\":\"{s}\"}}", .{database_path});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, find_reply);
}

test "set-database-origin for a path with no entry writes config.json and adds no entry" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const database_path = try std.fmt.allocPrint(allocator, "{s}/db-three", .{app.tmp_path});
    defer allocator.free(database_path);
    // Forward slashes: see the first set-database-origin test.
    std.mem.replaceScalar(u8, database_path, '\\', '/');
    const request = try std.fmt.allocPrint(allocator, "{{\"databasePath\":\"{s}\",\"origin\":\"/o\"}}", .{database_path});
    defer allocator.free(request);
    allocator.free(try app.requestOk("set-database-origin", request));
    const config_json = try readTestFile(&app, "db-three/.db/config.json");
    defer allocator.free(config_json);
    try std.testing.expect(std.mem.indexOf(u8, config_json, "\"origin\": \"/o\"") != null);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[]", list_reply);
}

test "set-database-origin without a database path is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("set-database-origin", "{\"origin\":\"/o\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The database needs a path.", reply);
}

test "list-s3-dirs replies an empty array when the vault holds no secret of that name" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("list-s3-dirs", "{\"s3Key\":\"databases-test-no-such-s3-secret\",\"bucket\":\"bucket\",\"prefix\":\"photos\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("[]", reply);
}

test "list-s3-dirs without a bucket is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("list-s3-dirs", "{\"s3Key\":\"k\",\"prefix\":\"p\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the name of the S3 bucket.", reply);
}

test "list-s3-dirs with a secret that is not JSON is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"databases-test-bad-s3-secret\",\"type\":\"s3-credentials\",\"value\":\"not json\"}"));
    const reply = try app.requestError("list-s3-dirs", "{\"s3Key\":\"databases-test-bad-s3-secret\",\"bucket\":\"bucket\",\"prefix\":\"p\"}");
    defer allocator.free(reply);
    try std.testing.expect(std.mem.startsWith(u8, reply, "The secret that holds the S3 credentials is not valid JSON"));
}

test "list-s3-dirs with a secret that is JSON null is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"databases-test-null-s3-secret\",\"type\":\"s3-credentials\",\"value\":\"null\"}"));
    const reply = try app.requestError("list-s3-dirs", "{\"s3Key\":\"databases-test-null-s3-secret\",\"bucket\":\"bucket\",\"prefix\":\"p\"}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("The secret that holds the S3 credentials is JSON null, so it holds no credentials.", reply);
}

test "update-database renaming onto the name of another entry is an error reply and changes nothing" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    try writeDatabasesToml(&app, "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");
    const reply = try app.requestError("update-database", "{\"originalName\":\"alpha\",\"entry\":{\"name\":\"BETA\",\"description\":\"\",\"path\":\"/a\"}}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("A database named \"BETA\" already exists.", reply);
    const list_reply = try app.requestOk("get-databases", "null");
    defer allocator.free(list_reply);
    try std.testing.expectEqualStrings("[{\"name\":\"alpha\",\"description\":\"\",\"path\":\"/a\"},{\"name\":\"beta\",\"description\":\"\",\"path\":\"/b\"}]", list_reply);
}

test "add-database logs that the entry was added" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    std.testing.allocator.free(try app.requestOk("add-database", "{\"name\":\"logged\",\"description\":\"\",\"path\":\"/logged\"}"));
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.writer.buffered(), "Database entry added") != null);
}

test "set-database-origin with an entry whose s3 secret is not JSON is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"databases-test-origin-bad-s3\",\"type\":\"s3-credentials\",\"value\":\"not json\"}"));
    try writeDatabasesToml(&app, "recent_database_names = []\n\n[[databases]]\nname = \"cloud\"\ndescription = \"\"\npath = \"/cloud-db\"\ns3_key = \"databases-test-origin-bad-s3\"\n");
    const reply = try app.requestError("set-database-origin", "{\"databasePath\":\"/cloud-db\",\"origin\":\"/o\"}");
    defer allocator.free(reply);
    try std.testing.expect(std.mem.startsWith(u8, reply, "The secret that holds the S3 credentials is not valid JSON"));
}
