const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
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

test "reads the file without writing to it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    const text = "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n";
    try writeToml(allocator, io, configDir, text);

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", config.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings(text, try readToml(allocator, io, configDir));
}

test "an unrecognised key leaves the recents empty and still writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);
    const text = "recent_database_paths = [ \"/a\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n";
    try writeToml(allocator, io, configDir, text);

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 1), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings(text, try readToml(allocator, io, configDir));
}

//
// Parses a TOML text into the object tomlToDatabasesConfig takes.
//
fn parseToml(allocator: std.mem.Allocator, text: []const u8) !std.json.ObjectMap {
    return (try node_utils.toml.parse(allocator, text)).object;
}

test "converts snake_case fields to camelCase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, "recent_database_names = [ \"test\" ]\n\n[[databases]]\nname = \"test\"\ndescription = \"\"\npath = \"/a\"\ns3_key = \"myKey\"\nencryption_key = \"encKey\"\ngeocoding_key = \"geoKey\"\n"));

    try std.testing.expectEqualStrings("myKey", config.databases[0].s3Key.?);
    try std.testing.expectEqualStrings("encKey", config.databases[0].encryptionKey.?);
    try std.testing.expectEqualStrings("geoKey", config.databases[0].geocodingKey.?);
    try std.testing.expectEqual(@as(usize, 1), config.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("test", config.recentDatabaseNames[0]);
}

test "coerces missing lists to empty ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, ""));

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
}

test "coerces lists that are not arrays to empty ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A hand-edited file can hold anything. `[recent_database_names]` written as a TOML table
    // parses to an object, which must not become the recents list.
    const config = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, "[databases]\n[recent_database_names]\n"));

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
}

test "reads last_database when the file names one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const withLast = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, "last_database = \"/photos\"\n"));
    try std.testing.expectEqualStrings("/photos", withLast.lastDatabase.?);

    const withoutLast = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, ""));
    try std.testing.expect(withoutLast.lastDatabase == null);
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


test "loadDatabasesConfig reads a databases.toml written by TypeScript like TypeScript does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer helpers.removeTempDir(io, configDir);

    const configJson =
        \\{"databases":[{"name":"Photos \"main\"","description":"My photos","path":"/home/me/photos","origin":"s3:bucket:/x","s3Key":"s3-creds","encryptionKey":"enc","geocodingKey":"geo"},{"name":"b","description":"","path":"C:\\data\\b"}],"recentDatabaseNames":["b","Photos \"main\""],"lastDatabase":"/home/me/photos"}
    ;
    _ = try helpers.runBun(allocator, io, "databases-config-ts.ts", &.{ "save", configJson }, &.{.{ "PHOTOSPHERE_CONFIG_DIR", configDir }});

    const loadedByTs = try helpers.runBunJson(allocator, io, "databases-config-ts.ts", &.{"load"}, &.{.{ "PHOTOSPHERE_CONFIG_DIR", configDir }});
    const loadedByZig = try databases_config.loadDatabasesConfig(allocator, io);
    const zigJson = try std.json.Stringify.valueAlloc(allocator, loadedByZig, .{ .emit_null_optional_fields = false });
    const tsJson = try std.json.Stringify.valueAlloc(allocator, loadedByTs, .{});
    try std.testing.expectEqualStrings(tsJson, zigJson);
}
