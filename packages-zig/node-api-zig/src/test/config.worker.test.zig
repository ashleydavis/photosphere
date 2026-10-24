//
// Tests for config.worker.zig.
//
// Tests for the mobile config.yaml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the databases.toml
// tests do: the point of the handlers is the bytes they put on disk. The settings are read by the
// app, by the background import and by the background sync, so what matters is that a file written
// by one is read by the others, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from
// a temporary directory standing in for that sandbox.
//
// Both features share the one file, so what only a shared file can get wrong is covered here too:
// one feature's write erasing the other's settings, and one feature's write making it look as though
// the other had already been chosen.
//

const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api = @import("api-zig");
const temp_dirs = @import("temp-dirs.zig");
const mock_log = @import("mock-log.zig");
const test_task_context = @import("test-task-context.zig");
const errors = utils.errors;
const config_worker = node_api.config_worker;
const readConfigHandler = config_worker.readConfigHandler;
const writeConfigHandler = config_worker.writeConfigHandler;
const readConfigFromStorage = config_worker.readConfigFromStorage;
const buildConfigYaml = config_worker.buildConfigYaml;
const TestTaskContext = test_task_context.TestTaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = api.auto_import_mobile.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const DEFAULT_SYNC_PAUSE_MS = api.sync_settings.DEFAULT_SYNC_PAUSE_MS;

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const CONFIG_PATH = "config.yaml";

//
// A temporary working directory standing in for the app's storage sandbox, the directory the test switches back to
// afterwards, and the task context the handlers take (they ignore it). Declare it, call init on it in place, and call
// deinit when the test is done.
//
const Sandbox = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The io the handlers use.
    io: std.Io,

    // The absolute path of the temporary directory.
    tempDir: []const u8,

    // The working directory before the test changed it.
    previousCwd: []const u8,

    // The uuids of the task context.
    uuidGenerator: TestUuidGenerator,

    // The task context the handlers take.
    taskContext: TestTaskContext,

    // Swallows what the code under test logs.
    mutedLog: mock_log.MutedLog,

    //
    // Makes the temporary directory and changes into it.
    //
    fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.io = std.testing.io;
        self.previousCwd = try std.process.currentPathAlloc(self.io, allocator);
        self.tempDir = try temp_dirs.makeTempDir(allocator, self.io, "config-worker");
        try std.process.setCurrentPath(self.io, self.tempDir);
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.taskContext.init(self.uuidGenerator.uuidGenerator());
        self.mutedLog = .{};
        self.mutedLog.install();
    }

    //
    // Changes back to the directory the test started in and removes the temporary one.
    //
    fn deinit(self: *Sandbox) void {
        self.mutedLog.uninstall();
        std.process.setCurrentPath(self.io, self.previousCwd) catch {
            @panic("The working directory could not be put back after a test.");
        };
        temp_dirs.removeTempDir(self.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Gets the allocator of the test.
    //
    fn arenaAllocator(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Writes the given text as the config file.
    //
    fn writeConfigText(self: *Sandbox, text: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = CONFIG_PATH,
            .data = text,
        });
    }

    //
    // Reads the config file back as a parsed document.
    //
    fn readConfigDocument(self: *Sandbox) !std.json.Value {
        const text = try std.Io.Dir.cwd().readFileAlloc(self.io, CONFIG_PATH, self.arenaAllocator(), .unlimited);
        return (try node_utils.yaml.load(self.arenaAllocator(), text));
    }

    //
    // Parses JSON text into a value.
    //
    fn json(self: *Sandbox, text: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arenaAllocator(), text, .{});
    }

    //
    // Runs the read-config handler for the config path and returns its result.
    //
    fn readConfig(self: *Sandbox, configPath: []const u8) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(self.arenaAllocator(), "configPath", .{
            .string = configPath,
        });
        return readConfigHandler(self.arenaAllocator(), self.io, test_timers.timers(), .{
            .object = object,
        }, self.taskContext.context.taskContext());
    }

    //
    // Runs the write-config handler with the JSON text as its data.
    //
    fn writeConfig(self: *Sandbox, dataJson: []const u8) !void {
        const result = try writeConfigHandler(self.arenaAllocator(), self.io, test_timers.timers(), try self.json(dataJson), self.taskContext.context.taskContext());
        try std.testing.expect(result == .null);
    }
};

//
// Gets the value at the dotted path of an object, or null when any step of it is missing.
//
fn at(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var steps = std.mem.splitScalar(u8, path, '.');
    while (steps.next()) |step| {
        if (current != .object) {
            return null;
        }
        current = current.object.get(step) orelse {
            return null;
        };
    }
    return current;
}

//
// Expects the value at the path to be this boolean.
//
fn expectBool(expected: bool, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected, found.bool);
}

//
// Expects the value at the path to be this integer.
//
fn expectInteger(expected: i64, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected, found.integer);
}

//
// Expects the value at the path to be this string.
//
fn expectString(expected: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(expected, found.string);
}

//
// Expects nothing to be at the path.
//
fn expectMissing(value: std.json.Value, path: []const u8) !void {
    try std.testing.expect(at(value, path) == null);
}

//
// Expects the value at the path to be an array holding exactly these strings.
//
fn expectStrings(expected: []const []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].string);
    }
}

//
// Expects the value at the path to be an array holding exactly this one device album.
//
fn expectOneAlbum(albumId: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(usize, 1), found.array.items.len);
    try std.testing.expectEqualStrings("device-album", found.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings(albumId, found.array.items[0].object.get("albumId").?.string);
}

//
// Expects the handler to fail with this message.
//
fn expectThrown(expectedMessage: []const u8, result: anytype) !void {
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

// The interface needs to tell "nobody has written this yet" from "somebody switched syncing off", because the first is a
// fresh install to seed and the second is a decision to leave alone, and both read as switched off.
test "reading a sandbox with no config file reports that neither feature's settings have been written" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "syncSettingsWritten");
    try expectBool(false, result, "autoImportSettingsWritten");
}

// The safe answer, and the whole reason the defaults are what they are: a background loop that cannot read its settings
// must not start pushing photos over a metered connection.
test "reading a sandbox with no config file yields both loops switched off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "sync.settings.enabled");
    try expectBool(true, result, "sync.settings.onlyOnWifi");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, result, "sync.pauseBetweenRunsMs");
    try expectBool(false, result, "autoImport.settings.enabled");
    try std.testing.expectEqual(@as(usize, 0), at(result, "autoImport.settings.sources").?.array.items.len);
    try expectMissing(result, "autoImport.defaultDatabasePath");
    try expectInteger(DEFAULT_AUTO_IMPORT_PAUSE_MS, result, "autoImport.pauseBetweenRunsMs");
}

// This file is written by the app and never shown to the user, so a copy that cannot be read is a bug somewhere else.
// Throwing here would take the settings card that could fix it down with it, and reading it as "sync over anything" would
// spend somebody's mobile data.
test "a corrupt config file reads as the defaults rather than throwing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("sync:\n  enabled: true\n   this: [is not yaml");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "sync.settings.enabled");
    try expectBool(true, result, "sync.settings.onlyOnWifi");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, result, "sync.pauseBetweenRunsMs");
    try expectBool(false, result, "autoImport.settings.enabled");
    try expectInteger(DEFAULT_AUTO_IMPORT_PAUSE_MS, result, "autoImport.pauseBetweenRunsMs");
}

// Nothing in it parsed, so nothing in it has been chosen: a fresh install must still be seeded rather than left believing
// its settings were already decided.
test "a corrupt config file reports that no section could be read" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("not: [valid");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "syncSettingsWritten");
    try expectBool(false, result, "autoImportSettingsWritten");
}

test "writing then reading round-trips the syncing settings and the pacing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":false},"databasePath":"photosphere-default","pauseBetweenRunsMs":60000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "sync.settings.enabled");
    try expectBool(false, result, "sync.settings.onlyOnWifi");
    try expectString("photosphere-default", result, "sync.databasePath");
    try expectInteger(60000, result, "sync.pauseBetweenRunsMs");
}

test "writing then reading round-trips the automatic import settings and the default database" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":true,"sources":[{"type":"device-album","albumId":"all"},{"type":"folder","path":"/photos/holiday","recurse":false}]},"defaultDatabasePath":"photosphere-default","pauseBetweenRunsMs":5000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "autoImport.settings.enabled");
    const sources = at(result, "autoImport.settings.sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("device-album", sources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("all", sources[0].object.get("albumId").?.string);
    try std.testing.expectEqual(@as(usize, 2), sources[0].object.count());
    try std.testing.expectEqualStrings("folder", sources[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("/photos/holiday", sources[1].object.get("path").?.string);
    try std.testing.expectEqual(false, sources[1].object.get("recurse").?.bool);
    try std.testing.expectEqual(@as(usize, 3), sources[1].object.count());
    try expectString("photosphere-default", result, "autoImport.defaultDatabasePath");
    try expectInteger(5000, result, "autoImport.pauseBetweenRunsMs");
}

test "writing then reading round-trips both sections written together" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":true,"sources":[{"type":"device-album","albumId":"all"}]},"defaultDatabasePath":"photosphere-default","pauseBetweenRunsMs":5000},"sync":{"settings":{"enabled":true,"onlyOnWifi":true},"databasePath":"photosphere-default","pauseBetweenRunsMs":60000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "autoImport.settings.enabled");
    try expectInteger(5000, result, "autoImport.pauseBetweenRunsMs");
    try expectBool(true, result, "sync.settings.enabled");
    try expectInteger(60000, result, "sync.pauseBetweenRunsMs");
}

test "writing then reading says a file that is there is there, even when it says both loops are off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":false,"onlyOnWifi":false},"pauseBetweenRunsMs":300000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "syncSettingsWritten");
    try expectBool(false, result, "sync.settings.enabled");
}

// The hazard that only exists now the two features share a file. They are switched on separately and their settings cards
// write independently, so a write that replaced the whole document would take the other feature's settings with it.
test "a write of one section leaves the others alone: writing the syncing settings keeps what automatic import watches" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":true,"sources":[{"type":"device-album","albumId":"holiday-album"}]},"defaultDatabasePath":"photosphere-default","pauseBetweenRunsMs":5000}}
    );
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":false},"pauseBetweenRunsMs":60000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "autoImport.settings.enabled");
    try expectOneAlbum("holiday-album", result, "autoImport.settings.sources");
    try expectString("photosphere-default", result, "autoImport.defaultDatabasePath");
    try expectInteger(5000, result, "autoImport.pauseBetweenRunsMs");
    try expectBool(true, result, "sync.settings.enabled");
}

test "a write of one section leaves the others alone: writing the automatic import settings keeps the syncing settings" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":false},"databasePath":"the-database-being-synced","pauseBetweenRunsMs":60000}}
    );
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":false,"sources":[]},"pauseBetweenRunsMs":5000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "sync.settings.enabled");
    try expectBool(false, result, "sync.settings.onlyOnWifi");
    try expectString("the-database-being-synced", result, "sync.databasePath");
    try expectInteger(60000, result, "sync.pauseBetweenRunsMs");
    try expectBool(false, result, "autoImport.settings.enabled");
}

// A desktop installation sharing this file writes sections this task has no notion of at all. Reading before writing is
// what keeps them.
test "a write of one section leaves the others alone: keeps settings the task knows nothing about, such as the theme and the saved searches" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("theme: dark\ndeveloper_mode: true\nshow_fps_indicator: true\nsaved_searches:\n  - beach\n");
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":true},"pauseBetweenRunsMs":60000}}
    );

    const document = try sandbox.readConfigDocument();

    try expectString("dark", document, "theme");
    try expectBool(true, document, "developer_mode");
    try expectBool(true, document, "show_fps_indicator");
    try expectStrings(&.{"beach"}, document, "saved_searches");
    try expectBool(true, document, "sync.enabled");
}

// Which settings have been chosen is asked per feature, not of the file.
//
// The two used to be files of their own, so "the file is there" answered "have these settings been chosen?". With one file it
// does not: automatic import writing its own section brings the file into being, and a fresh install would then be told its
// syncing settings had already been decided. The interface skips its seeding step on that answer, so the phone would sit with
// syncing switched off while both toggles said it was on.
test "whether a feature's settings have been written: writing only the automatic import settings does not claim the syncing settings were chosen" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":true,"sources":[{"type":"device-album","albumId":"all"}]},"pauseBetweenRunsMs":5000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "autoImportSettingsWritten");
    try expectBool(false, result, "syncSettingsWritten");
}

test "whether a feature's settings have been written: writing only the syncing settings does not claim the automatic import settings were chosen" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":true},"pauseBetweenRunsMs":60000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "syncSettingsWritten");
    try expectBool(false, result, "autoImportSettingsWritten");
}

test "whether a feature's settings have been written: a file holding only another platform's settings claims neither" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("theme: dark\ndesktop:\n  last_folder: /home/someone/photos\n");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "syncSettingsWritten");
    try expectBool(false, result, "autoImportSettingsWritten");
}

test "whether a feature's settings have been written: both are claimed once both have been written" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":false,"sources":[]},"pauseBetweenRunsMs":5000},"sync":{"settings":{"enabled":false,"onlyOnWifi":true},"pauseBetweenRunsMs":60000}}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "syncSettingsWritten");
    try expectBool(true, result, "autoImportSettingsWritten");
}

// Asserted on the file itself, because anything else that opens it (a smoke test seeding settings from outside the app, a
// person looking at what their phone is doing) reads these names rather than the camelCase ones used in memory.
test "the file on disk is YAML with snake_case keys nested by feature" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","autoImport":{"settings":{"enabled":true,"sources":[{"type":"device-album","albumId":"all"}]},"defaultDatabasePath":"photosphere-default","pauseBetweenRunsMs":30000},"sync":{"settings":{"enabled":true,"onlyOnWifi":true},"pauseBetweenRunsMs":300000}}
    );

    const document = try sandbox.readConfigDocument();

    try expectBool(true, document, "auto_import.enabled");
    try expectString("photosphere-default", document, "auto_import.default_database_path");
    try expectInteger(30000, document, "auto_import.pause_between_runs_ms");
    const sources = at(document, "auto_import.sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqual(@as(usize, 2), sources[0].object.count());
    try std.testing.expectEqualStrings("device-album", sources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("all", sources[0].object.get("album_id").?.string);
    try expectBool(true, document, "sync.enabled");
    try expectBool(true, document, "sync.only_on_wifi");
    try expectInteger(300000, document, "sync.pause_between_runs_ms");
}

// A gap of zero is a loop that starts a fresh pass the instant the last one ended, which on a phone is a flat battery rather
// than a fast backup. The value can only get here by hand, so it is corrected on the way in and on the way out.
test "values a hand-edited file may hold: a gap of zero or less falls back to the default rather than spinning" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("auto_import:\n  enabled: true\n  pause_between_runs_ms: 0\nsync:\n  enabled: true\n  pause_between_runs_ms: 0\n");

    const zeroGap = try sandbox.readConfig(CONFIG_PATH);
    try expectInteger(DEFAULT_AUTO_IMPORT_PAUSE_MS, zeroGap, "autoImport.pauseBetweenRunsMs");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, zeroGap, "sync.pauseBetweenRunsMs");

    try sandbox.writeConfigText("auto_import:\n  pause_between_runs_ms: -1000\nsync:\n  pause_between_runs_ms: -1000\n");

    const negativeGap = try sandbox.readConfig(CONFIG_PATH);
    try expectInteger(DEFAULT_AUTO_IMPORT_PAUSE_MS, negativeGap, "autoImport.pauseBetweenRunsMs");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, negativeGap, "sync.pauseBetweenRunsMs");
}

// The string "false" is truthy, so coercing it would switch syncing on for somebody who wrote the opposite.
test "values a hand-edited file may hold: a value that is not a boolean is not taken as one" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("sync:\n  enabled: \"false\"\n  only_on_wifi: \"no\"\n");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(false, result, "sync.settings.enabled");
    try expectBool(true, result, "sync.settings.onlyOnWifi");
}

test "values a hand-edited file may hold: a missing setting falls back rather than being left undefined" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("sync:\n  enabled: true\n");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectBool(true, result, "sync.settings.enabled");
    try expectBool(true, result, "sync.settings.onlyOnWifi");
}

test "values a hand-edited file may hold: a malformed source is dropped rather than taken as a place to watch" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfigText("auto_import:\n  enabled: true\n  sources:\n    - type: device-album\n      album_id: all\n    - type: folder\n");

    const result = try sandbox.readConfig(CONFIG_PATH);

    try expectOneAlbum("all", result, "autoImport.settings.sources");
}

// buildConfigYaml is what a host-side script uses to seed a device's settings, so it has to produce exactly the file the
// handler would have written.
test "buildConfigYaml produces a document the reader reads back as the input" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const allocator = sandbox.arenaAllocator();
    var config = try node_api.config_format.defaultConfigFile(allocator);
    config.autoImport = .{
        .settings = .{
            .enabled = true,
            .sources = &.{},
        },
        .defaultDatabasePath = null,
        .pauseBetweenRunsMs = .{
            .integer = 1000,
        },
    };
    config.sync = .{
        .settings = .{
            .enabled = true,
            .onlyOnWifi = false,
        },
        .databasePath = "photosphere-default",
        .pauseBetweenRunsMs = .{
            .integer = 120000,
        },
    };
    const rendered = try buildConfigYaml(allocator, config, null);

    try sandbox.writeConfigText(rendered);

    const contents = (try readConfigFromStorage(allocator, sandbox.io, CONFIG_PATH)).config;

    try std.testing.expectEqual(true, contents.autoImport.settings.enabled);
    try std.testing.expect(contents.autoImport.defaultDatabasePath == null);
    try std.testing.expectEqual(@as(i64, 1000), contents.autoImport.pauseBetweenRunsMs.integer);
    try std.testing.expectEqual(true, contents.sync.settings.enabled);
    try std.testing.expectEqual(false, contents.sync.settings.onlyOnWifi);
    try std.testing.expectEqualStrings("photosphere-default", contents.sync.databasePath.?);
    try std.testing.expectEqual(@as(i64, 120000), contents.sync.pauseBetweenRunsMs.integer);
}

test "bad input to the handlers: a write with no config path fails rather than writing somewhere else" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("configPath is required", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"","sync":{"settings":{"enabled":true,"onlyOnWifi":true},"pauseBetweenRunsMs":300000}}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a read with no config path fails rather than reading somewhere else" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("configPath is required", sandbox.readConfig(""));
}

// A write with no section at all would silently rewrite the file with what it already held, which looks like it worked and
// changes nothing. It is always a caller bug, so it is loud.
test "bad input to the handlers: a write with nothing to write fails rather than doing nothing quietly" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("write-config was given no autoImport section, no sync section and no settings to write, so there is nothing to write.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml"}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a setting with no key fails rather than being written under an empty name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("write-config was given a setting with no key.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","entries":[{"key":"","value":true}]}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a write of a section with no settings fails rather than writing a default" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("autoImport.settings is required", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","autoImport":{"pauseBetweenRunsMs":5000}}
    ), sandbox.taskContext.context.taskContext()));
    try expectThrown("sync.settings is required", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","sync":{"pauseBetweenRunsMs":5000}}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a config path that is not a string fails with a sentence" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("The read-config task data is not valid: configPath must be a string", readConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":5}
    ), sandbox.taskContext.context.taskContext()));
    try expectThrown("The write-config task data is not valid: configPath must be a string, and autoImport, sync and entries must hold their parts", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":5}
    ), sandbox.taskContext.context.taskContext()));
}

// The settings the interface names, which is how a phone reads and writes what the desktop app and the CLI keep in this same
// file. Each one goes to the section the format puts it in. A key this file does not hold is not this handler's business: the
// routing sends it to state.yaml instead.
test "the settings the interface names: a setting the format declares is written into its own section and read back by name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":"dark"}]}
    );

    try expectString("dark", try sandbox.readConfigDocument(), "theme");
    try expectString("dark", try sandbox.readConfig(CONFIG_PATH), "settings.theme");
}

test "the settings the interface names: the searches the user saved are written at the top level and read back by name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"savedSearches","value":["beach","dogs"]}]}
    );

    try expectStrings(&.{ "beach", "dogs" }, try sandbox.readConfigDocument(), "saved_searches");
    try expectStrings(&.{ "beach", "dogs" }, try sandbox.readConfig(CONFIG_PATH), "settings.savedSearches");
}

test "the settings the interface names: an entry with no value clears the setting rather than leaving it as it was" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":"dark"}]}
    );
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme"}]}
    );

    try expectMissing(try sandbox.readConfigDocument(), "theme");
    try expectMissing(try sandbox.readConfig(CONFIG_PATH), "settings.theme");
}

test "the settings the interface names: writing a setting leaves a feature's settings exactly as they were" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","sync":{"settings":{"enabled":true,"onlyOnWifi":false},"databasePath":"the-database","pauseBetweenRunsMs":90000}}
    );

    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":"light"}]}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);
    try expectBool(true, result, "sync.settings.enabled");
    try expectBool(false, result, "sync.settings.onlyOnWifi");
    try expectString("the-database", result, "sync.databasePath");
    try expectInteger(90000, result, "sync.pauseBetweenRunsMs");
    try expectString("light", result, "settings.theme");
}

// A fresh install seeds syncing on, and only skips that when the file says syncing has been chosen already. An empty sync
// section left behind by an unrelated write would say exactly that, and the phone would sit with syncing off and its toggles
// saying on.
test "the settings the interface names: writing a setting does not make it look as though syncing had been decided" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":"light"}]}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);
    try expectBool(false, result, "syncSettingsWritten");
    try expectBool(false, result, "autoImportSettingsWritten");
    try expectMissing(try sandbox.readConfigDocument(), "sync");
}

// The routing sends it to state.yaml, so config.yaml never carries it and reading it back through this handler has to come up
// empty rather than finding a stale copy.
test "the settings the interface names: a setting the state file holds is not answered from here" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":"dark"}]}
    );

    const result = try sandbox.readConfig(CONFIG_PATH);
    try expectMissing(result, "settings.gallerySort");
    try expectMissing(result, "settings.sidebar-collapsed-databases");
}

test "the settings the interface names: a switch is written as a boolean and read back by name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"developerMode","value":true}]}
    );

    try expectBool(true, try sandbox.readConfig(CONFIG_PATH), "settings.developerMode");
}

test "the settings the interface names: the places automatic import watches are written as sources and read back by name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeConfig(
        \\{"configPath":"config.yaml","entries":[{"key":"autoImportSources","value":[{"type":"folder","path":"/photos","recurse":true}]}]}
    );

    const sources = at(try sandbox.readConfig(CONFIG_PATH), "settings.autoImportSources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("folder", sources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("/photos", sources[0].object.get("path").?.string);
}

test "bad input to the handlers: a place to watch that is neither a folder nor an album fails rather than being dropped" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("The config setting \"autoImportSources\" was given a place to watch that is not a folder or a device album.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","entries":[{"key":"autoImportSources","value":[{"type":"cloud"}]}]}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a list holding something other than text fails rather than being stored" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("The config setting \"savedSearches\" was given a list that holds something other than text.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","entries":[{"key":"savedSearches","value":["beach",3]}]}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a value no setting can hold fails rather than being stored" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("The config setting \"theme\" cannot hold that kind of value.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","entries":[{"key":"theme","value":{"name":"dark"}}]}
    ), sandbox.taskContext.context.taskContext()));
}

test "bad input to the handlers: a number for a switch fails rather than being stored" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("The config setting \"developerMode\" cannot hold a value of that type.", writeConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"config.yaml","entries":[{"key":"developerMode","value":1}]}
    ), sandbox.taskContext.context.taskContext()));
}
