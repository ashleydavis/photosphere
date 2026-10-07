const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const databases_config = node_api.databases_config;
const databases_config_format = node_api.databases_config_format;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn useNewConfigDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, "config");
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", dir);
    return dir;
}

//
// Writes databases.toml in the config dir.
//
fn writeToml(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), text);
}

//
// Reads databases.toml from the config dir.
//
fn readToml(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    return test_files.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}));
}

test "the paths of databases.toml and state.yaml are joined and normalized as path.join does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    const unnormalized = try std.fmt.allocPrint(allocator, "{s}/./sub/..//", .{configDir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", unnormalized);

    const expectedDatabases = try node_utils.path.join(allocator, &.{ configDir, "databases.toml" });
    const expectedState = try node_utils.path.join(allocator, &.{ configDir, "state.yaml" });
    try std.testing.expect(std.mem.indexOf(u8, expectedDatabases, "..") == null);
    try std.testing.expectEqualStrings(expectedDatabases, try node_api.databases_config.getDatabasesConfigPath(allocator));
    try std.testing.expectEqualStrings(expectedState, try node_api.state_file.getStatePath(allocator));
}

test "returns default config when no file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);

    const config = try databases_config.loadDatabasesConfig(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), config.databases.len);
    try std.testing.expectEqual(@as(usize, 0), config.recentDatabaseNames.len);
    try std.testing.expect(!test_files.fileExists(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir})));
}

test "returns config from TOML when file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);
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
    defer temp_dirs.removeTempDir(io, configDir);

    // The config TypeScript's updateDatabasesConfig was handed: every optional field on the first entry, none on
    // the second, and strings that TOML has to escape.
    const configJson =
        \\{"databases":[{"name":"Photos \"main\"","description":"My photos","path":"/home/me/photos","origin":"s3:bucket:/x","s3Key":"s3-creds","encryptionKey":"enc","geocodingKey":"geo"},{"name":"b","description":"","path":"C:\\data\\b"}],"recentDatabaseNames":["b","Photos \"main\""],"lastDatabase":"/home/me/photos"}
    ;

    // The file it writes: databasesConfigToToml (packages/node-api/src/lib/databases-config.ts) gives
    // `{ databases, recent_database_names, last_database }` with each entry's keys in databaseEntryToToml's order, and
    // smol-toml's stringify puts the plain keys first, then each array of tables as `[[databases]]` blocks separated
    // by a blank line, with every string written as JSON.stringify writes it.
    try writeToml(allocator, io, configDir,
        \\recent_database_names = [ "b", "Photos \"main\"" ]
        \\last_database = "/home/me/photos"
        \\
        \\[[databases]]
        \\name = "Photos \"main\""
        \\description = "My photos"
        \\path = "/home/me/photos"
        \\origin = "s3:bucket:/x"
        \\s3_key = "s3-creds"
        \\encryption_key = "enc"
        \\geocoding_key = "geo"
        \\
        \\[[databases]]
        \\name = "b"
        \\description = ""
        \\path = "C:\\data\\b"
        \\
    );

    // TypeScript's loadDatabasesConfig reads back the config it was handed (tomlToDatabasesConfig undoes
    // databasesConfigToToml).
    const loaded = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqualStrings(configJson, try std.json.Stringify.valueAlloc(allocator, loaded, .{ .emit_null_optional_fields = false }));
}

test "converts camelCase fields to snake_case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entry: databases_config.IDatabaseEntry = .{
        .name = "test",
        .description = "",
        .path = "/a",
        .s3Key = "myKey",
        .encryptionKey = "encKey",
        .geocodingKey = "geoKey",
    };

    const toml = try databases_config.databasesConfigToToml(allocator, .{
        .databases = &.{entry},
        .recentDatabaseNames = &.{"test"},
    });

    const tomlEntry = toml.object.get("databases").?.array.items[0].object;
    try std.testing.expectEqualStrings("myKey", tomlEntry.get("s3_key").?.string);
    try std.testing.expectEqualStrings("encKey", tomlEntry.get("encryption_key").?.string);
    try std.testing.expectEqualStrings("geoKey", tomlEntry.get("geocoding_key").?.string);
    try std.testing.expect(tomlEntry.get("s3Key") == null);
    const recents = toml.object.get("recent_database_names").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), recents.len);
    try std.testing.expectEqualStrings("test", recents[0].string);
}

test "round trips a config through TOML and back unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original: databases_config.IDatabasesConfig = .{
        .databases = &.{
            .{
                .name = "alpha",
                .description = "",
                .path = "/a",
            },
            .{
                .name = "beta",
                .description = "",
                .path = "/b",
            },
        },
        .recentDatabaseNames = &.{"beta"},
    };

    const roundTripped = try databases_config.tomlToDatabasesConfig(allocator, (try databases_config.databasesConfigToToml(allocator, original)).object);

    try std.testing.expectEqualStrings(try configAsJson(allocator, original), try configAsJson(allocator, roundTripped));
}

//
// The config as JSON (the `toEqual` of the TypeScript tests).
//
fn configAsJson(allocator: std.mem.Allocator, config: databases_config.IDatabasesConfig) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, config, .{
        .emit_null_optional_fields = false,
    });
}

test "matches regardless of case" {
    try std.testing.expect(databases_config.namesMatch("Alpha", "alpha"));
    try std.testing.expect(databases_config.namesMatch("ALPHA", "alpha"));
}

test "does not match different names" {
    try std.testing.expect(!databases_config.namesMatch("alpha", "beta"));
    try std.testing.expect(!databases_config.namesMatch("alpha", "alpha2"));
}

//
// A mutator for the updateDatabasesConfig tests: records the config it is handed and returns `result`, or the config
// it was handed when `result` is null, or throws when `fail` is set.
//
const RecordingMutator = struct {
    // The config the mutator was handed.
    seen: ?databases_config.IDatabasesConfig = null,

    // What the mutator returns, or null to return what it was handed.
    result: ?databases_config.IDatabasesConfig = null,

    // True to throw instead of returning.
    fail: bool = false,

    //
    // Records the config and returns the result.
    //
    pub fn run(self: *RecordingMutator, allocator: std.mem.Allocator, config: databases_config.IDatabasesConfig) !databases_config.IDatabasesConfig {
        _ = allocator;
        self.seen = config;
        if (self.fail) {
            return utils.errors.throwError("no", .{});
        }
        return self.result orelse config;
    }
};

test "hands the mutator the current contents of the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");
    var mutator: RecordingMutator = .{};

    try databases_config.updateDatabasesConfig(allocator, io, &mutator);

    try std.testing.expectEqualStrings("alpha", mutator.seen.?.databases[0].name);
    try std.testing.expectEqual(@as(usize, 1), mutator.seen.?.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", mutator.seen.?.recentDatabaseNames[0]);
}

test "hands the mutator an empty config when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    var mutator: RecordingMutator = .{};

    try databases_config.updateDatabasesConfig(allocator, io, &mutator);

    try std.testing.expectEqualStrings("{\"databases\":[],\"recentDatabaseNames\":[]}", try configAsJson(allocator, mutator.seen.?));
}

test "writes what the mutator returns, converted to TOML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "databases = []\nrecent_database_names = []\n");
    var mutator: RecordingMutator = .{
        .result = .{
            .databases = &.{
                .{
                    .name = "alpha",
                    .description = "",
                    .path = "/a",
                },
            },
            .recentDatabaseNames = &.{"alpha"},
        },
    };

    try databases_config.updateDatabasesConfig(allocator, io, &mutator);

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqualStrings("/a", written.databases[0].path);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", written.recentDatabaseNames[0]);
}

test "lets a throwing mutator through, writing nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    const text = "databases = []\nrecent_database_names = []\n";
    try writeToml(allocator, io, configDir, text);
    var mutator: RecordingMutator = .{
        .fail = true,
    };

    try std.testing.expectError(error.Thrown, databases_config.updateDatabasesConfig(allocator, io, &mutator));

    try std.testing.expectEqualStrings("no", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings(text, try readToml(allocator, io, configDir));
}

test "returns undefined when no entry matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try std.testing.expect((try databases_config.findDatabase(allocator, io, "beta")) == null);
}

test "returns entry on case-insensitive match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"Alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    const result = try databases_config.findDatabase(allocator, io, "ALPHA");

    try std.testing.expectEqualStrings("Alpha", result.?.name);
}

test "appends entry and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.addDatabaseEntry(allocator, io, .{
        .name = "beta",
        .description = "",
        .path = "/b",
    });

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), written.databases.len);
    try std.testing.expectEqualStrings("/b", written.databases[1].path);
}

test "throws on case-insensitive name collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    const text = "recent_database_names = []\n\n[[databases]]\nname = \"Alpha\"\ndescription = \"\"\npath = \"/a\"\n";
    try writeToml(allocator, io, configDir, text);

    try std.testing.expectError(error.Thrown, databases_config.addDatabaseEntry(allocator, io, .{
        .name = "ALPHA",
        .description = "",
        .path = "/b",
    }));

    try std.testing.expectEqualStrings("A database named \"ALPHA\" already exists.", utils.errors.lastErrorMessage());
    // The mutator throws inside the lock, so nothing is written.
    try std.testing.expectEqualStrings(text, try readToml(allocator, io, configDir));
}

test "replaces matched entry by originalName and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.updateDatabaseEntry(allocator, io, "alpha", .{
        .name = "alpha",
        .description = "changed",
        .path = "/a",
    });

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqualStrings("changed", written.databases[0].description);
}

test "rewrites the matching recent slot when renaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"beta\", \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    try databases_config.updateDatabaseEntry(allocator, io, "alpha", .{
        .name = "gamma",
        .description = "",
        .path = "/a",
    });

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqualStrings("gamma", written.databases[0].name);
    try std.testing.expectEqual(@as(usize, 2), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("beta", written.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("gamma", written.recentDatabaseNames[1]);
}

test "throws when rename collides with another entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    const text = "recent_database_names = []\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n";
    try writeToml(allocator, io, configDir, text);

    try std.testing.expectError(error.Thrown, databases_config.updateDatabaseEntry(allocator, io, "alpha", .{
        .name = "BETA",
        .description = "",
        .path = "/a",
    }));

    try std.testing.expectEqualStrings("A database named \"BETA\" already exists.", utils.errors.lastErrorMessage());
    // The mutator throws inside the lock, so nothing is written.
    try std.testing.expectEqualStrings(text, try readToml(allocator, io, configDir));
}

test "throws when no entry matches originalName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "databases = []\nrecent_database_names = []\n");

    try std.testing.expectError(error.Thrown, databases_config.updateDatabaseEntry(allocator, io, "missing", .{
        .name = "missing",
        .description = "",
        .path = "/x",
    }));

    try std.testing.expectEqualStrings("No database named \"missing\" found.", utils.errors.lastErrorMessage());
}

test "removes only the first matching entry by name and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = []\n\n[[databases]]\nname = \"dup\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"dup\"\ndescription = \"\"\npath = \"/b\"\n\n[[databases]]\nname = \"unique\"\ndescription = \"\"\npath = \"/c\"\n");

    try databases_config.removeDatabaseEntry(allocator, io, "dup");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), written.databases.len);
    try std.testing.expectEqualStrings("/b", written.databases[0].path);
    try std.testing.expectEqualStrings("/c", written.databases[1].path);
}

test "also removes the name from recents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\", \"beta\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    try databases_config.removeDatabaseEntry(allocator, io, "alpha");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("beta", written.recentDatabaseNames[0]);
}

test "idempotent when name not found and recents already clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.removeDatabaseEntry(allocator, io, "missing");

    // Nothing to remove, so the contents come back unchanged.
    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), written.databases.len);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", written.recentDatabaseNames[0]);
}

test "addDatabaseEntry writes databases.toml as TypeScript writes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"b\", \"Photos \\\"main\\\"\" ]\nlast_database = \"/home/me/photos\"\n\n[[databases]]\nname = \"b\"\ndescription = \"\"\npath = \"C:\\\\data\\\\b\"\n");

    try databases_config.addDatabaseEntry(allocator, io, .{
        .name = "Photos \"main\"",
        .description = "My photos",
        .path = "/home/me/photos",
        .origin = "s3:bucket:/x",
        .s3Key = "s3-creds",
        .encryptionKey = "enc",
        .geocodingKey = "geo",
    });

    // What TypeScript's addDatabaseEntry writes for the same file and entry (smol-toml's stringify of
    // databasesConfigToToml: the plain keys first, then each entry as a `[[databases]]` block, in
    // databaseEntryToToml's key order).
    try std.testing.expectEqualStrings(
        \\recent_database_names = [ "b", "Photos \"main\"" ]
        \\last_database = "/home/me/photos"
        \\
        \\[[databases]]
        \\name = "b"
        \\description = ""
        \\path = "C:\\data\\b"
        \\
        \\[[databases]]
        \\name = "Photos \"main\""
        \\description = "My photos"
        \\path = "/home/me/photos"
        \\origin = "s3:bucket:/x"
        \\s3_key = "s3-creds"
        \\encryption_key = "enc"
        \\geocoding_key = "geo"
        \\
    , try readToml(allocator, io, configDir));
}

//
// tomlEntryToDatabaseEntry reads a TOML entry object into the in-memory entry type. The three keys it always copies
// read as "" when they are absent or are not text (TypeScript copies whatever is there, so a hand-edited entry that
// omits one leaves it undefined), and each optional key is carried over only when it is text.
//
test "tomlEntryToDatabaseEntry carries the three required keys and the optional ones that are there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const full = databases_config_format.tomlEntryToDatabaseEntry(try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"name":"Photos","description":"My photos","path":"/a","origin":"s3:bucket:/x","s3_key":"s3","encryption_key":"enc","geocoding_key":"geo"}
    , .{}));
    try std.testing.expectEqualStrings("Photos", full.name);
    try std.testing.expectEqualStrings("My photos", full.description);
    try std.testing.expectEqualStrings("/a", full.path);
    try std.testing.expectEqualStrings("s3:bucket:/x", full.origin.?);
    try std.testing.expectEqualStrings("s3", full.s3Key.?);
    try std.testing.expectEqualStrings("enc", full.encryptionKey.?);
    try std.testing.expectEqualStrings("geo", full.geocodingKey.?);

    const bare = databases_config_format.tomlEntryToDatabaseEntry(try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"name":"Photos","description":"","path":"/a"}
    , .{}));
    try std.testing.expectEqualStrings("Photos", bare.name);
    try std.testing.expectEqualStrings("", bare.description);
    try std.testing.expect(bare.origin == null);
    try std.testing.expect(bare.s3Key == null);
    try std.testing.expect(bare.encryptionKey == null);
    try std.testing.expect(bare.geocodingKey == null);
}

//
// The optional keys are carried only when they are text, and an entry that is not an object at all reads as one with
// every key empty. In TypeScript an optional key holding a number would be carried as that number, and an entry that
// is not an object would have its properties read as undefined.
//
test "tomlEntryToDatabaseEntry drops an optional key that is not text, and reads a non-object entry as all empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const withNumber = databases_config_format.tomlEntryToDatabaseEntry(try std.json.parseFromSliceLeaky(std.json.Value, allocator,
        \\{"name":"Photos","description":"","path":"/a","origin":7}
    , .{}));
    try std.testing.expect(withNumber.origin == null);

    const notAnObject = databases_config_format.tomlEntryToDatabaseEntry(.null);
    try std.testing.expectEqualStrings("", notAnObject.name);
    try std.testing.expectEqualStrings("", notAnObject.description);
    try std.testing.expectEqualStrings("", notAnObject.path);
    try std.testing.expect(notAnObject.origin == null);
}

//
// databaseEntryToToml writes the three keys it always has and each optional key only when the entry has one, in the
// order tomlEntryToDatabaseEntry reads them back.
//
test "databaseEntryToToml leaves out every optional key the entry does not have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bare = try databases_config_format.databaseEntryToToml(allocator, .{
        .name = "Photos",
        .description = "",
        .path = "/a",
    });
    try std.testing.expectEqualStrings(
        \\{"name":"Photos","description":"","path":"/a"}
    , try std.json.Stringify.valueAlloc(allocator, bare, .{}));

    const full = try databases_config_format.databaseEntryToToml(allocator, .{
        .name = "Photos",
        .description = "My photos",
        .path = "/a",
        .origin = "s3:bucket:/x",
        .s3Key = "s3",
        .encryptionKey = "enc",
        .geocodingKey = "geo",
    });
    try std.testing.expectEqualStrings(
        \\{"name":"Photos","description":"My photos","path":"/a","origin":"s3:bucket:/x","s3_key":"s3","encryption_key":"enc","geocoding_key":"geo"}
    , try std.json.Stringify.valueAlloc(allocator, full, .{}));

    // Reading it back gives the same entry, so the two conversions are inverses.
    const roundTripped = databases_config_format.tomlEntryToDatabaseEntry(full);
    try std.testing.expectEqualStrings("Photos", roundTripped.name);
    try std.testing.expectEqualStrings("My photos", roundTripped.description);
    try std.testing.expectEqualStrings("/a", roundTripped.path);
    try std.testing.expectEqualStrings("s3:bucket:/x", roundTripped.origin.?);
    try std.testing.expectEqualStrings("s3", roundTripped.s3Key.?);
    try std.testing.expectEqualStrings("enc", roundTripped.encryptionKey.?);
    try std.testing.expectEqualStrings("geo", roundTripped.geocodingKey.?);
}

test "getRecentDatabases returns the entries named by the recents in recents order and drops names that match no entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"BETA\", \"gone\", \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    const recent = try databases_config.getRecentDatabases(allocator, io);

    try std.testing.expectEqual(@as(usize, 2), recent.len);
    try std.testing.expectEqualStrings("/b", recent[0].path);
    try std.testing.expectEqualStrings("/a", recent[1].path);
}

test "getRecentDatabases returns nothing when there is no file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);

    const recent = try databases_config.getRecentDatabases(allocator, io);

    try std.testing.expectEqual(@as(usize, 0), recent.len);
}

test "removeRecentDatabaseName removes only the name from the recents and keeps the entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\", \"beta\" ]\nlast_database = \"/b\"\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    try databases_config.removeRecentDatabaseName(allocator, io, "ALPHA");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), written.databases.len);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("beta", written.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("/b", written.lastDatabase.?);
}

test "removeRecentDatabaseName leaves the recents alone when the name is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.removeRecentDatabaseName(allocator, io, "missing");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", written.recentDatabaseNames[0]);
}

test "markDatabaseOpened moves the entry's own name to the front without repeating it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\", \"beta\" ]\n\n[[databases]]\nname = \"Alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    try databases_config.markDatabaseOpened(allocator, io, "BETA");
    try databases_config.markDatabaseOpened(allocator, io, "alpha");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("Alpha", written.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("beta", written.recentDatabaseNames[1]);
}

test "markDatabaseOpened keeps at most MAX_RECENT_DATABASES names, dropping the oldest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"d1\", \"d2\", \"d3\", \"d4\", \"d5\" ]\n\n[[databases]]\nname = \"d1\"\ndescription = \"\"\npath = \"/1\"\n\n[[databases]]\nname = \"d2\"\ndescription = \"\"\npath = \"/2\"\n\n[[databases]]\nname = \"d3\"\ndescription = \"\"\npath = \"/3\"\n\n[[databases]]\nname = \"d4\"\ndescription = \"\"\npath = \"/4\"\n\n[[databases]]\nname = \"d5\"\ndescription = \"\"\npath = \"/5\"\n\n[[databases]]\nname = \"d6\"\ndescription = \"\"\npath = \"/6\"\n");

    try databases_config.markDatabaseOpened(allocator, io, "d6");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 5), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("d6", written.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("d4", written.recentDatabaseNames[4]);
}

test "markDatabaseOpened does nothing when no entry matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.markDatabaseOpened(allocator, io, "missing");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 1), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("alpha", written.recentDatabaseNames[0]);
}

test "getLastDatabase is null when none is recorded and the path when one is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try std.testing.expect((try databases_config.getLastDatabase(allocator, io)) == null);
    try writeToml(allocator, io, configDir, "recent_database_names = []\ndatabases = []\nlast_database = \"/some/db\"\n");

    const last = try databases_config.getLastDatabase(allocator, io);

    try std.testing.expectEqualStrings("/some/db", last.?);
}

test "setLastDatabase records the path, carries the lists through, and null clears it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.setLastDatabase(allocator, io, "/a");

    const afterSet = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqualStrings("/a", afterSet.lastDatabase.?);
    try std.testing.expectEqual(@as(usize, 1), afterSet.databases.len);
    try std.testing.expectEqual(@as(usize, 1), afterSet.recentDatabaseNames.len);

    try databases_config.setLastDatabase(allocator, io, null);

    const afterClear = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expect(afterClear.lastDatabase == null);
    try std.testing.expectEqual(@as(usize, 1), afterClear.databases.len);
    const text = try readToml(allocator, io, configDir);
    try std.testing.expect(std.mem.indexOf(u8, text, "last_database") == null);
}

test "the last database survives every other edit to the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\nlast_database = \"/a\"\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try databases_config.addDatabaseEntry(allocator, io, .{ .name = "beta", .description = "", .path = "/b" });
    try std.testing.expectEqualStrings("/a", (try databases_config.getLastDatabase(allocator, io)).?);

    try databases_config.updateDatabaseEntry(allocator, io, "beta", .{ .name = "gamma", .description = "", .path = "/b" });
    try std.testing.expectEqualStrings("/a", (try databases_config.getLastDatabase(allocator, io)).?);

    try databases_config.markDatabaseOpened(allocator, io, "alpha");
    try std.testing.expectEqualStrings("/a", (try databases_config.getLastDatabase(allocator, io)).?);

    try databases_config.removeRecentDatabaseName(allocator, io, "alpha");
    try std.testing.expectEqualStrings("/a", (try databases_config.getLastDatabase(allocator, io)).?);

    try databases_config.removeDatabaseEntry(allocator, io, "gamma");
    try std.testing.expectEqualStrings("/a", (try databases_config.getLastDatabase(allocator, io)).?);
}

test "the last opened database is undefined when the file names none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n");

    try std.testing.expect((try databases_config.getLastDatabase(allocator, io)) == null);
}

test "setting the last opened database leaves the databases and recents lists exactly as they were" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try useNewConfigDir(allocator, io);
    defer temp_dirs.removeTempDir(io, configDir);
    try writeToml(allocator, io, configDir, "recent_database_names = [ \"beta\", \"alpha\" ]\n\n[[databases]]\nname = \"alpha\"\ndescription = \"\"\npath = \"/a\"\n\n[[databases]]\nname = \"beta\"\ndescription = \"\"\npath = \"/b\"\n");

    try databases_config.setLastDatabase(allocator, io, "/b");

    const written = try databases_config.loadDatabasesConfig(allocator, io);
    try std.testing.expectEqual(@as(usize, 2), written.databases.len);
    try std.testing.expectEqualStrings("alpha", written.databases[0].name);
    try std.testing.expectEqualStrings("/a", written.databases[0].path);
    try std.testing.expectEqualStrings("beta", written.databases[1].name);
    try std.testing.expectEqualStrings("/b", written.databases[1].path);
    try std.testing.expectEqual(@as(usize, 2), written.recentDatabaseNames.len);
    try std.testing.expectEqualStrings("beta", written.recentDatabaseNames[0]);
    try std.testing.expectEqualStrings("alpha", written.recentDatabaseNames[1]);
}

test "the last opened database round-trips through the TOML conversions in both directions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const withLast = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, "last_database = \"/a\"\n"));
    const withoutLast = try databases_config.tomlToDatabasesConfig(allocator, try parseToml(allocator, ""));
    const tomlWithLast = try databases_config.databasesConfigToToml(allocator, .{
        .databases = &.{},
        .recentDatabaseNames = &.{},
        .lastDatabase = "/a",
    });
    const tomlWithoutLast = try databases_config.databasesConfigToToml(allocator, .{
        .databases = &.{},
        .recentDatabaseNames = &.{},
    });

    try std.testing.expectEqualStrings("/a", withLast.lastDatabase.?);
    try std.testing.expect(withoutLast.lastDatabase == null);
    try std.testing.expectEqualStrings("/a", tomlWithLast.object.get("last_database").?.string);
    try std.testing.expect(tomlWithoutLast.object.get("last_database") == null);
}
