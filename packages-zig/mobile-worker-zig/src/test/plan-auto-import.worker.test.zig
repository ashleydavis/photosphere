//
// Tests for plan-auto-import.worker.zig.
//
// Tests for the task the native background import asks what to do.
//
// The deciding itself (whether to run, which database, what to watch) is planMobileAutoImport and is
// covered in packages/api. What is covered here is the task around it: that it reads the settings
// from the file rather than from anywhere else, and that the steps it hands back are the tasks a pass
// has to run. Native code runs those steps unchanged and builds no payload of its own, so
// getting them wrong here is getting the background import wrong on both platforms at once.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading that file is the part of the task under test.
//

const std = @import("std");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const mobile_worker = @import("mobile-worker-zig");
const sandbox_module = @import("sandbox.zig");
const Sandbox = sandbox_module.Sandbox;
const planAutoImportHandler = mobile_worker.plan_auto_import_worker.planAutoImportHandler;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = api.auto_import_mobile.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const DEFAULT_DATABASE_FOLDER_NAME = api.auto_import_mobile.DEFAULT_DATABASE_FOLDER_NAME;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;
const buildConfigYaml = node_api.config_worker.buildConfigYaml;
const at = sandbox_module.at;
const stepData = sandbox_module.stepData;

//
// Writes the automatic import settings into the temporary sandbox's config.yaml, exactly as the app would, leaving every
// other section of the file as it is.
// (Zig: the sources are the JSON text of the list, which the settings are read from.)
//
fn writeSettingsFile(sandbox: *Sandbox, enabled: bool, defaultDatabasePath: ?[]const u8, sourcesJson: []const u8, pauseBetweenRunsMs: i64) !void {
    const allocator = sandbox.arenaAllocator();
    var config = (try readConfigFromStorage(allocator, sandbox.io, "config.yaml")).config;
    const settingsJson = try std.fmt.allocPrint(allocator, "{{\"enabled\":{s},\"sources\":{s}}}", .{ if (enabled) "true" else "false", sourcesJson });
    config.autoImport = .{
        .settings = try api.auto_import_settings.normaliseAutoImportSettings(allocator, try sandbox.json(settingsJson)),
        .defaultDatabasePath = defaultDatabasePath,
        .pauseBetweenRunsMs = .{
            .integer = pauseBetweenRunsMs,
        },
    };
    try sandbox.writeFile("config.yaml", try buildConfigYaml(allocator, config, null));
}

//
// Runs the handler.
//
fn plan(sandbox: *Sandbox) !std.json.Value {
    return planAutoImportHandler(sandbox.arenaAllocator(), sandbox.io, .{
        .object = .empty,
    }, sandbox.context());
}

// A phone that has never switched automatic import on. Nothing must run, and nothing must be handed back for the service to run
// either.
test "plan-auto-import says not to run when there is no settings file at all" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try plan(&sandbox);

    try sandbox_module.expectBool(false, result, "shouldRun");
    try sandbox_module.expectEmptyArray(result, "steps");
}

test "plan-auto-import says not to run when the settings say off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, false, "photosphere-default", "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try plan(&sandbox);

    try sandbox_module.expectBool(false, result, "shouldRun");
    try sandbox_module.expectEmptyArray(result, "steps");
}

test "plan-auto-import creates and records the default database when there is not one yet" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, null, "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try plan(&sandbox);

    try sandbox_module.expectBool(true, result, "shouldRun");
    try sandbox_module.expectBool(true, result, "isNewDefault");
    try sandbox_module.expectString(DEFAULT_DATABASE_FOLDER_NAME, result, "databasePath");
    try sandbox_module.expectKeyStrings(&.{ "create-default-database", "import-assets" }, "type", result, "steps");
    const created = stepData(at(result, "steps").?, "create-default-database").?;
    try std.testing.expectEqual(@as(usize, 4), created.object.count());
    try sandbox_module.expectString(DEFAULT_DATABASE_FOLDER_NAME, created, "databasePath");
    try sandbox_module.expectString(try node_api.config_file.getConfigPath(sandbox.arenaAllocator()), created, "configPath");
    try sandbox_module.expectString(try node_api.databases_config.getDatabasesConfigPath(sandbox.arenaAllocator()), created, "databasesConfigPath");

    // Asked for on screen as well as on disk: photos are about to start arriving in it, and a gallery showing nothing while they
    // do is the thing this asks for.
    try sandbox_module.expectBool(true, created, "open");
}

// Recorded first rather than last, because an import that fails must not leave the next pass creating the database a second time
// on top of the one that is already there.
test "plan-auto-import records the database before importing into it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, null, "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try plan(&sandbox);

    var recordIndex: ?usize = null;
    var importIndex: ?usize = null;
    for (at(result, "steps").?.array.items, 0..) |step, index| {
        const stepType = step.object.get("type").?.string;
        if (recordIndex == null and std.mem.eql(u8, stepType, "create-default-database")) {
            recordIndex = index;
        }
        if (importIndex == null and std.mem.eql(u8, stepType, "import-assets")) {
            importIndex = index;
        }
    }
    try std.testing.expect(recordIndex != null);
    try std.testing.expect(importIndex != null);
    try std.testing.expect(recordIndex.? < importIndex.?);
}

test "plan-auto-import imports straight into the chosen database once there is one" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "my-photos", "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try plan(&sandbox);

    try sandbox_module.expectBool(false, result, "isNewDefault");
    try sandbox_module.expectString("my-photos", result, "databasePath");
    try sandbox_module.expectKeyStrings(&.{"import-assets"}, "type", result, "steps");
}

test "plan-auto-import passes the configured places to watch through to the import" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "my-photos", "[{\"type\":\"device-album\",\"albumId\":\"holiday-album\"},{\"type\":\"device-album\",\"albumId\":\"pets\"}]", 5000);

    const result = try plan(&sandbox);

    const settingsSources = at(result, "settings.sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), settingsSources.len);
    try std.testing.expectEqualStrings("holiday-album", settingsSources[0].object.get("albumId").?.string);
    try std.testing.expectEqualStrings("pets", settingsSources[1].object.get("albumId").?.string);
    const importSources = at(stepData(at(result, "steps").?, "import-assets").?, "options.sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), importSources.len);
    try std.testing.expectEqualStrings("device-album", importSources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("holiday-album", importSources[0].object.get("albumId").?.string);
    try std.testing.expectEqualStrings("device-album", importSources[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("pets", importSources[1].object.get("albumId").?.string);
}

// Running with no sources at all would import nothing while looking like it was working, which is the worst of both.
test "plan-auto-import watches the whole photo library when no album has been chosen" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "my-photos", "[]", 5000);

    const result = try plan(&sandbox);

    try sandbox_module.expectBool(true, result, "shouldRun");
    const importSources = at(stepData(at(result, "steps").?, "import-assets").?, "options.sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), importSources.len);
    try std.testing.expectEqualStrings("device-album", importSources[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("all", importSources[0].object.get("albumId").?.string);
}

test "plan-auto-import's import step is a real automatic import into the planned database" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "my-photos", "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try plan(&sandbox);
    const importData = stepData(at(result, "steps").?, "import-assets").?;

    try sandbox_module.expectEmptyArray(importData, "paths");
    try std.testing.expectEqual(@as(usize, 1), at(importData, "storageDescriptor").?.object.count());
    try sandbox_module.expectString("my-photos", importData, "storageDescriptor.databasePath");
    try sandbox_module.expectBool(false, importData, "dryRun");
    try sandbox_module.expectString("test-session-id", importData, "sessionId");
    try sandbox_module.expectBool(true, importData, "options.auto");
    try sandbox_module.expectBool(true, importData, "options.enabled");
    try sandbox_module.expectString("auto-import:my-photos", importData, "job.id");
    try sandbox_module.expectString("Automatic import", importData, "job.name");
    try std.testing.expectEqual(@as(usize, 2), at(importData, "job").?.object.count());
}

test "plan-auto-import carries the gap between passes from the settings file" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "my-photos", "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 1500);

    const result = try plan(&sandbox);

    try sandbox_module.expectInteger(1500, result, "pauseBetweenRunsMs");
}

test "plan-auto-import: a gap of zero in the file falls back to the default rather than spinning" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeFile("config.yaml", "auto_import:\n  enabled: true\n  default_database_path: my-photos\n  pause_between_runs_ms: 0\n");

    const result = try plan(&sandbox);

    try sandbox_module.expectInteger(DEFAULT_AUTO_IMPORT_PAUSE_MS, result, "pauseBetweenRunsMs");
}

test "plan-auto-import puts a new default database in the app data directory when the request names one" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, null, "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try planAutoImportHandler(sandbox.arenaAllocator(), sandbox.io, try sandbox.json("{\"appDataPath\":\"/data/app\"}"), sandbox.context());

    // Joined the way the platform joins paths, as the desktop TypeScript test expects it.
    const expectedPath = try node_utils.path.join(sandbox.arenaAllocator(), &.{ "/data/app", DEFAULT_DATABASE_FOLDER_NAME });
    try sandbox_module.expectString(expectedPath, result, "databasePath");
    const created = stepData(at(result, "steps").?, "create-default-database").?;
    try sandbox_module.expectString(expectedPath, created, "databasePath");
    const imported = stepData(at(result, "steps").?, "import-assets").?;
    try sandbox_module.expectString(expectedPath, at(imported, "storageDescriptor").?, "databasePath");
}

test "plan-auto-import keeps the database the user chose, whatever data directory the request names" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSettingsFile(&sandbox, true, "/elsewhere/my-photos", "[{\"type\":\"device-album\",\"albumId\":\"all\"}]", 5000);

    const result = try planAutoImportHandler(sandbox.arenaAllocator(), sandbox.io, try sandbox.json("{\"appDataPath\":\"/data/app\"}"), sandbox.context());

    try sandbox_module.expectString("/elsewhere/my-photos", result, "databasePath");
}
