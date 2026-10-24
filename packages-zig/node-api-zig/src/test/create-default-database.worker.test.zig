//
// Tests for the task that creates the default database and records it. Every platform runs this one,
// so what a default database is cannot differ between them.
//
// The three things it does have to happen together: a database recorded as the default but missing
// from the list is one the user cannot open, and a database that exists but is recorded nowhere is
// created again on the next pass, on top of the one that is already there.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because a real database and the two files are what it is for.
//

const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const api = @import("api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const DEFAULT_DATABASE_DISPLAY_NAME = api.auto_import_mobile.DEFAULT_DATABASE_DISPLAY_NAME;
const createDefaultDatabaseHandler = node_api.create_default_database_worker.createDefaultDatabaseHandler;
const readConfigHandler = node_api.config_worker.readConfigHandler;
const buildConfigYaml = node_api.config_worker.buildConfigYaml;
const readDatabasesConfigHandler = node_api.databases_config_worker.readDatabasesConfigHandler;
const defaultConfigFile = node_api.config_format.defaultConfigFile;
const checkDatabaseExists = node_api.media_file_database.checkDatabaseExists;
const addDatabaseEntry = node_api.databases_config.addDatabaseEntry;
const markDatabaseOpened = node_api.databases_config.markDatabaseOpened;
const setLastDatabase = node_api.databases_config.setLastDatabase;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// What each test works in: a temporary directory standing in for the app's storage sandbox, holding the database the task
// creates and the two files it records it in. The config directory is pointed at it too, so the databases.toml the task
// writes is the one the tests read and add to with the databases-config functions.
//
const Sandbox = struct {
    // The environment of the test (see test-environment.zig), freed by deinit.
    test_env: *test_environment.TestEnvironment,

    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The temporary directory.
    tempDir: []const u8,

    // The database the task creates.
    databasePath: []const u8,

    // The path of config.yaml.
    configPath: []const u8,

    // The path of databases.toml.
    databasesConfigPath: []const u8,

    // The task context. The database it creates is stamped with the identifiers from here.
    context: RecordingTaskContext,

    //
    // Makes the temporary directory.
    //
    fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        self.test_env = try test_environment.setupEnvironment(io);
        self.tempDir = try temp_dirs.makeTempDir(allocator, io, "create-default-database");
        try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", self.tempDir);
        self.databasePath = try std.fs.path.join(allocator, &.{ self.tempDir, "photosphere-default" });
        self.configPath = try std.fs.path.join(allocator, &.{ self.tempDir, "config.yaml" });
        self.databasesConfigPath = try std.fs.path.join(allocator, &.{ self.tempDir, "databases.toml" });
        try self.context.init(allocator, null, null);
    }

    //
    // Removes the temporary directory.
    //
    fn deinit(self: *Sandbox) void {
        temp_dirs.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
        self.test_env.deinit();
    }

    //
    // Runs the task for the sandbox's paths.
    //
    fn run(self: *Sandbox, open: bool) !std.json.Value {
        const allocator = self.arena.allocator();
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "databasePath", .{
            .string = self.databasePath,
        });
        try object.put(allocator, "configPath", .{
            .string = self.configPath,
        });
        try object.put(allocator, "databasesConfigPath", .{
            .string = self.databasesConfigPath,
        });
        try object.put(allocator, "open", .{
            .bool = open,
        });
        return createDefaultDatabaseHandler(allocator, std.testing.io, test_timers.timers(), .{
            .object = object,
        }, self.context.taskContext());
    }

    //
    // Reads the settings back through the read-config task.
    //
    fn readSettings(self: *Sandbox) !std.json.ObjectMap {
        const allocator = self.arena.allocator();
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "configPath", .{
            .string = self.configPath,
        });
        return (try readConfigHandler(allocator, std.testing.io, test_timers.timers(), .{
            .object = object,
        }, self.context.taskContext())).object;
    }

    //
    // Reads the database list back through the read-databases-config task.
    //
    fn readDatabases(self: *Sandbox) !std.json.ObjectMap {
        const allocator = self.arena.allocator();
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "configPath", .{
            .string = self.databasesConfigPath,
        });
        return (try readDatabasesConfigHandler(allocator, std.testing.io, test_timers.timers(), .{
            .object = object,
        }, self.context.taskContext())).object;
    }

    //
    // Writes a config.yaml holding the given automatic import and syncing settings.
    //
    fn writeConfig(self: *Sandbox, albumId: []const u8, autoImportPauseMs: i64, syncEnabled: bool, syncOnlyOnWifi: bool, syncDatabasePath: ?[]const u8, syncPauseMs: i64) !void {
        const allocator = self.arena.allocator();
        var config = try defaultConfigFile(allocator);
        config.autoImport = .{
            .settings = .{
                .enabled = true,
                .sources = &.{.{
                    .@"device-album" = .{
                        .albumId = albumId,
                    },
                }},
            },
            .defaultDatabasePath = null,
            .pauseBetweenRunsMs = .{
                .integer = autoImportPauseMs,
            },
        };
        config.sync = .{
            .settings = .{
                .enabled = syncEnabled,
                .onlyOnWifi = syncOnlyOnWifi,
            },
            .databasePath = syncDatabasePath,
            .pauseBetweenRunsMs = .{
                .integer = syncPauseMs,
            },
        };
        try test_files.writeFile(std.testing.io, self.configPath, try buildConfigYaml(allocator, config, null));
    }
};

//
// The paths of the entries of a database list.
//
fn entryPaths(allocator: std.mem.Allocator, databases: std.json.ObjectMap) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (databases.get("databases").?.array.items) |entry| {
        try paths.append(allocator, entry.object.get("path").?.string);
    }
    return paths.items;
}

test "creates a real database at the path" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const output = try sandbox.run(true);

    try std.testing.expect(output == .null);
    try std.testing.expect(try checkDatabaseExists(sandbox.arena.allocator(), std.testing.io, sandbox.databasePath, null));
}

test "records the database as the default and adds it to the database list" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig("all", 5000, false, true, null, 300000);

    _ = try sandbox.run(true);

    const settings = try sandbox.readSettings();
    try std.testing.expectEqualStrings(sandbox.databasePath, settings.get("autoImport").?.object.get("defaultDatabasePath").?.string);

    const databases = try sandbox.readDatabases();
    const entries = databases.get("databases").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(DEFAULT_DATABASE_DISPLAY_NAME, entries[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("", entries[0].object.get("description").?.string);
    try std.testing.expectEqualStrings(sandbox.databasePath, entries[0].object.get("path").?.string);
}

test "records the database when there is no settings file and no database list yet" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    _ = try sandbox.run(true);

    const settings = try sandbox.readSettings();
    try std.testing.expectEqualStrings(sandbox.databasePath, settings.get("autoImport").?.object.get("defaultDatabasePath").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try sandbox.readDatabases()).get("databases").?.array.items.len);
}

test "leaves the rest of the settings exactly as it found them" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    // The pass that creates the database runs while the user may be changing the settings, and
    // this write must not undo what they chose.
    try sandbox.writeConfig("holiday-album", 1500, true, false, "a-database-the-user-opened", 90000);

    _ = try sandbox.run(true);

    const settings = try sandbox.readSettings();
    const autoImport = settings.get("autoImport").?.object;
    try std.testing.expectEqual(true, autoImport.get("settings").?.object.get("enabled").?.bool);
    const sources = autoImport.get("settings").?.object.get("sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("device-album", sources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("holiday-album", sources[0].object.get("albumId").?.string);
    try std.testing.expectEqual(@as(i64, 1500), autoImport.get("pauseBetweenRunsMs").?.integer);

    // The syncing settings share the file and must survive this write untouched.
    const sync = settings.get("sync").?.object;
    try std.testing.expectEqual(true, sync.get("settings").?.object.get("enabled").?.bool);
    try std.testing.expectEqual(false, sync.get("settings").?.object.get("onlyOnWifi").?.bool);
    try std.testing.expectEqualStrings("a-database-the-user-opened", sync.get("databasePath").?.string);
    try std.testing.expectEqual(@as(i64, 90000), sync.get("pauseBetweenRunsMs").?.integer);
}

test "keeps the databases the user already has" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const allocator = sandbox.arena.allocator();
    const io = std.testing.io;
    try addDatabaseEntry(allocator, io, .{
        .name = "Holiday",
        .description = "Trip photos",
        .path = "holiday",
    });
    try markDatabaseOpened(allocator, io, "Holiday");

    _ = try sandbox.run(true);

    const databases = try sandbox.readDatabases();
    const paths = try entryPaths(allocator, databases);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("holiday", paths[0]);
    try std.testing.expectEqualStrings(sandbox.databasePath, paths[1]);
    const recentNames = databases.get("recentDatabaseNames").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), recentNames.len);
    try std.testing.expectEqualStrings("Holiday", recentNames[0].string);
}

test "keeps the database the user had open" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const allocator = sandbox.arena.allocator();
    const io = std.testing.io;
    try addDatabaseEntry(allocator, io, .{
        .name = "Holiday",
        .description = "Trip photos",
        .path = "holiday",
    });
    try setLastDatabase(allocator, io, "holiday");

    _ = try sandbox.run(true);

    // Writing the list without it would close the database the user had open.
    const databases = try sandbox.readDatabases();
    try std.testing.expectEqualStrings("holiday", databases.get("lastDatabase").?.string);
}

test "recording the same database twice does not list it twice" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    // A pass can be interrupted after the database is recorded and before the import finishes, so
    // the next pass may record it again.
    _ = try sandbox.run(true);
    _ = try sandbox.run(true);

    const paths = try entryPaths(sandbox.arena.allocator(), try sandbox.readDatabases());
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings(sandbox.databasePath, paths[0]);
}

test "does not create the database again when one is already there" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const allocator = sandbox.arena.allocator();
    const io = std.testing.io;

    // A pass that was killed between making the database and recording it leaves one behind.
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    sandbox.databasePath = databaseDir;

    _ = try sandbox.run(true);

    const settings = try sandbox.readSettings();
    try std.testing.expectEqualStrings(databaseDir, settings.get("autoImport").?.object.get("defaultDatabasePath").?.string);
    const paths = try entryPaths(allocator, try sandbox.readDatabases());
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings(databaseDir, paths[0]);
}

test "tells the interface to open the database it made" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    // The one way the task reaches the interface on every platform: the main process
    // forwards a task message to the renderer.
    _ = try sandbox.run(true);

    try std.testing.expectEqual(@as(usize, 1), sandbox.context.messages.items.len);
    const message = sandbox.context.messages.items[0].object;
    try std.testing.expectEqual(@as(u32, 2), message.count());
    try std.testing.expectEqualStrings("database-opened", message.get("type").?.string);
    try std.testing.expectEqualStrings(sandbox.databasePath, message.get("databasePath").?.string);
}

test "says nothing when the database was not asked for on screen" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    // Made on disk and recorded, but the user is not taken to it.
    _ = try sandbox.run(false);

    try std.testing.expectEqual(@as(usize, 0), sandbox.context.messages.items.len);
    const settings = try sandbox.readSettings();
    try std.testing.expectEqualStrings(sandbox.databasePath, settings.get("autoImport").?.object.get("defaultDatabasePath").?.string);
}

test "still says so for a database that was already listed" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    // The second pass over a database that exists and is recorded still has to open it: the
    // interface asking for it is a separate thing from the database being new.
    _ = try sandbox.run(true);
    sandbox.context.messages.clearRetainingCapacity();

    _ = try sandbox.run(true);

    try std.testing.expectEqual(@as(usize, 1), sandbox.context.messages.items.len);
    const message = sandbox.context.messages.items[0].object;
    try std.testing.expectEqualStrings("database-opened", message.get("type").?.string);
    try std.testing.expectEqualStrings(sandbox.databasePath, message.get("databasePath").?.string);
}

test "a missing database path is refused rather than recorded as nothing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    sandbox.databasePath = "";

    try std.testing.expectError(error.Thrown, sandbox.run(true));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "a missing config path is refused" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    sandbox.configPath = "";

    try std.testing.expectError(error.Thrown, sandbox.run(true));
    try std.testing.expectEqualStrings("configPath is required", errors.lastErrorMessage());
    try std.testing.expect(!try checkDatabaseExists(sandbox.arena.allocator(), std.testing.io, sandbox.databasePath, null));
}

test "a missing databases config path is refused" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    sandbox.databasesConfigPath = "";

    try std.testing.expectError(error.Thrown, sandbox.run(true));
    try std.testing.expectEqualStrings("databasesConfigPath is required", errors.lastErrorMessage());
    try std.testing.expect(!try checkDatabaseExists(sandbox.arena.allocator(), std.testing.io, sandbox.databasePath, null));
}

test "throws a descriptive error when the task data is not valid" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const allocator = sandbox.arena.allocator();
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{
        .integer = 5,
    });

    try std.testing.expectError(error.Thrown, createDefaultDatabaseHandler(allocator, std.testing.io, test_timers.timers(), .{
        .object = object,
    }, sandbox.context.taskContext()));
    try std.testing.expectEqualStrings("The create-default-database task data is not valid: databasePath, configPath and databasesConfigPath must be strings and open must be a boolean", errors.lastErrorMessage());
}
