const std = @import("std");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const databases_config = node_api.databases_config;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn useNewConfigDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = try helpers.setupEnvironment(io);
    const dir = try helpers.makeTempDir(allocator, io, "config");
    try helpers.setEnv("PHOTOSPHERE_CONFIG_DIR", dir);
    return dir;
}

//
// Writes databases.toml in the config dir.
//
fn writeToml(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), text);
}

//
// Reads databases.toml from the config dir.
//
fn readToml(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}));
}

test "returns default config when no file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
    try std.testing.expect(!helpers.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir})));
}

test "returns config from TOML when file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), config.databases.len);
    try std.testing.expectEqualStrings("/a", config.databases[0].path);
    try std.testing.expectEqual(@as(usize, 1), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", config.recentDatabaseNames[0]);
}

test "coerces missing databases to []" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
}

test "coerces missing recent_database_names to []" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/a\"\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
}

test "converts snake_case TOML fields to camelCase TypeScript fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"test\"\ndescription = \"\"\npath = \"/a\"\ns3_key = \"myKey\"\nencryption_key = \"encKey\"\ngeocoding_key = \"geoKey\"\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqualStrings("myKey", config.databases[0].s3Key.?);
    try std.testing.expectEqualStrings("encKey", config.databases[0].encryptionKey.?);
    try std.testing.expectEqualStrings("geoKey", config.databases[0].geocodingKey.?);
    try std.testing.expect(config.databases[0].origin == null);
}

test "migrates from JSON when TOML does not exist but JSON does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    const jsonPath = try std.fmt.allocPrint(allocator, "{s}/databases.json", .{configDir});
    try helpers.writeFile(io, jsonPath, "{\"databases\":[{\"name\":\"alpha\",\"description\":\"\",\"path\":\"/a\"}],\"recentDatabasePaths\":[\"/a\"]}");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), config.databases.len);
    try std.testing.expectEqualStrings("/a", config.databases[0].path);
    try std.testing.expectEqual(@as(usize, 1), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", config.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings(
        "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n",
        try readToml(allocator, io, configDir),
    );
    try std.testing.expect(!helpers.fileExists(io, jsonPath));
}

test "coerces missing arrays when migrating from JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.json", .{configDir}), "{}");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
}

test "migrates legacy recent_database_paths to recent_database_names and rewrites the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_paths = [ \"/b\", \"/a\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 2), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("beta", config.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("alpha", config.recentDatabaseNames[1]);
    const rewritten = try readToml(allocator, io, configDir);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "recent_database_names = [ \"beta\", \"alpha\" ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "recent_database_paths") == null);
}

test "drops legacy paths that no longer match any database during migration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_paths = [ \"/missing\", \"/a\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", config.recentDatabaseNames[0]);
}

test "writes TOML with snake_case keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);

    try databases_config.saveDatabasesConfig(allocator, io, .{
        .databases = &.{.{ .name = "db", .description = "", .path = "/a" }},
        .recentDatabaseNames = &.{},
    });

    try std.testing.expectEqualStrings(
        "recent_database_names = []\n\n[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/a\"\n",
        try readToml(allocator, io, configDir),
    );
}

test "converts camelCase entry fields to snake_case in TOML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);

    try databases_config.saveDatabasesConfig(allocator, io, .{
        .databases = &.{.{ .name = "test", .description = "", .path = "/a", .s3Key = "myKey", .encryptionKey = "encKey", .geocodingKey = "geoKey" }},
        .recentDatabaseNames = &.{},
    });

    const written = try readToml(allocator, io, configDir);
    try std.testing.expect(std.mem.indexOf(u8, written, "s3_key = \"myKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "encryption_key = \"encKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "geocoding_key = \"geoKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "s3Key") == null);
}

test "coerces missing arrays before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);

    try databases_config.saveDatabasesConfig(allocator, io, .{ .databases = &.{}, .recentDatabaseNames = &.{} });

    try std.testing.expectEqualStrings("databases = []\nrecent_database_names = []\n", try readToml(allocator, io, configDir));
}

test "returns the databases array from config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/b\"\n");

    const result = try databases_config.getDatabases(allocator, io);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/a", result[0].path);
    try std.testing.expectEqualStrings("/b", result[1].path);
}

test "saveDatabasesConfig writes the same bytes as the TypeScript saveDatabasesConfig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    const tsConfigDir = try helpers.makeTempDir(allocator, io, "config-ts");
    defer helpers.removeTempDir(io, tsConfigDir);

    const configJson =
        \\{"databases":[{"name":"Photos \"main\"","description":"My photos","path":"/home/me/photos","origin":"s3:bucket:/x","s3Key":"s3-creds","encryptionKey":"enc","geocodingKey":"geo"},{"name":"b","description":"","path":"C:\\data\\b"}],"recentDatabaseNames":["b","Photos \"main\""]}
    ;
    _ = try helpers.runBun(allocator, io, "databases-config-ts.ts", &.{ "save", configJson }, &.{.{ "PHOTOSPHERE_CONFIG_DIR", tsConfigDir }});

    try databases_config.saveDatabasesConfig(allocator, io, .{
        .databases = &.{
            .{ .name = "Photos \"main\"", .description = "My photos", .path = "/home/me/photos", .origin = "s3:bucket:/x", .s3Key = "s3-creds", .encryptionKey = "enc", .geocodingKey = "geo" },
            .{ .name = "b", .description = "", .path = "C:\\data\\b" },
        },
        .recentDatabaseNames = &.{ "b", "Photos \"main\"" },
    });

    try std.testing.expectEqualStrings(try readToml(allocator, io, tsConfigDir), try readToml(allocator, io, configDir));

    // TypeScript loads what Zig wrote, and Zig loads what TypeScript wrote, to the same entries.
    const loadedByTs = try helpers.runBunJson(allocator, io, "databases-config-ts.ts", &.{"load"}, &.{.{ "PHOTOSPHERE_CONFIG_DIR", configDir }});
    const loadedByZig = try databases_config.loadDatabasesConfig(allocator, io);
    const zigJson = try std.json.Stringify.valueAlloc(allocator, loadedByZig, .{ .emit_null_optional_fields = false });
    const tsJson = try std.json.Stringify.valueAlloc(allocator, loadedByTs, .{});
    try std.testing.expectEqualStrings(tsJson, zigJson);
}
