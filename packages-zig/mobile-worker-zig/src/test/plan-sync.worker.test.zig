//
// Tests for plan-sync.worker.zig.
//
// Tests for the task the native background sync asks what to do.
//
// Every way a sync can be refused is a test here, because each one is a promise the app makes: the
// master switch is what a user reaches for when they want syncing to stop, and the Wi-Fi-only
// restriction is what stands between an automatic backup and somebody's mobile data bill. The rule
// itself is computeSyncAllowed and is covered in packages/api; what is covered here is that this task
// reads the right settings, asks the platform for the connection type, and applies that rule rather
// than a second copy of it.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading those files is part of what is under test.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const test_timers = @import("test-timers.zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const mobile_worker = @import("mobile-worker-zig");
const expectBool = @import("sandbox.zig").expectBool;
const expectContains = @import("sandbox.zig").expectContains;
const expectEmptyArray = @import("sandbox.zig").expectEmptyArray;
const expectInteger = @import("sandbox.zig").expectInteger;
const expectKeyStrings = @import("sandbox.zig").expectKeyStrings;
const expectString = @import("sandbox.zig").expectString;
const test_hosts = @import("test-hosts.zig");
const Sandbox = @import("sandbox.zig").Sandbox;
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const ReportingHost = test_hosts.ReportingHost;
const planSyncHandler = mobile_worker.plan_sync_worker.planSyncHandler;
const DEFAULT_SYNC_PAUSE_MS = api.sync_settings.DEFAULT_SYNC_PAUSE_MS;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;
const buildConfigYaml = node_api.config_worker.buildConfigYaml;
const at = @import("sandbox.zig").at;

//
// The database the tests use, which stands in for the one automatic import creates.
//
const DATABASE_PATH = "photosphere-default";

//
// Writes the syncing settings into the temporary sandbox's config.yaml, exactly as the app would.
//
// It reads what is already there and puts back only the syncing section, because the two features
// share one file now: rebuilding the document from the syncing settings alone would delete whatever
// automatic import had been told to watch.
//
fn writeSyncSettings(sandbox: *Sandbox, log: ILog, enabled: bool, onlyOnWifi: bool, pauseBetweenRunsMs: i64) !void {
    const allocator = sandbox.arenaAllocator();
    var config = (try readConfigFromStorage(allocator, sandbox.io, log, "config.yaml")).config;
    config.sync = .{
        .settings = .{
            .enabled = enabled,
            .onlyOnWifi = onlyOnWifi,
        },
        .databasePath = null,
        .pauseBetweenRunsMs = .{
            .integer = pauseBetweenRunsMs,
        },
    };
    try sandbox.writeFile("config.yaml", try buildConfigYaml(allocator, config, null));
}

//
// Writes the automatic import section naming the database background sync falls back to, exactly as
// the app would, leaving the syncing settings as they are.
//
fn writeDefaultDatabase(sandbox: *Sandbox, log: ILog, defaultDatabasePath: ?[]const u8) !void {
    const allocator = sandbox.arenaAllocator();
    var config = (try readConfigFromStorage(allocator, sandbox.io, log, "config.yaml")).config;
    config.autoImport = .{
        .settings = .{
            .enabled = true,
            .sources = &[_]api.auto_import_settings.IAutoImportSource{
                .{
                    .@"device-album" = .{
                        .albumId = "all",
                    },
                },
            },
        },
        .defaultDatabasePath = defaultDatabasePath,
        .pauseBetweenRunsMs = .{
            .integer = 30000,
        },
    };
    try sandbox.writeFile("config.yaml", try buildConfigYaml(allocator, config, null));
}

//
// Creates the database directory with a config naming an origin, or with no origin at all.
//
fn writeDatabaseConfig(sandbox: *Sandbox, origin: ?[]const u8) !void {
    const text = if (origin) |originPath|
        try std.fmt.allocPrint(sandbox.arenaAllocator(), "{{\n  \"origin\": \"{s}\"\n}}", .{originPath})
    else
        "{}";
    try sandbox.writeFile(DATABASE_PATH ++ "/.db/config.json", text);
}

//
// Sets up everything a sync needs, so a test only has to change the one thing it is about.
//
fn setUpSyncableDatabase(sandbox: *Sandbox, log: ILog) !void {
    try writeDefaultDatabase(sandbox, log, DATABASE_PATH);
    try writeDatabaseConfig(sandbox, "/somewhere/else/photos");
}

//
// Runs the handler with the data as JSON text, on a host reporting the connection type.
//
fn plan(sandbox: *Sandbox, log: ILog, connectionType: []const u8, dataJson: []const u8) !std.json.Value {
    var host: ReportingHost = .{
        .reported = connectionType,
    };
    return planSyncHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), log, try sandbox.json(dataJson), sandbox.context(), host.networkStatusHost());
}

// A phone whose settings cannot be read must not start pushing photos over whatever connection it happens to have. Off is the only
// safe reading of a file that is not there.
test "plan-sync says not to sync when there is no settings file at all" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
}

// The master switch, and the first thing checked: it is what a user reaches for when they want syncing to stop, so nothing else can
// get past it.
test "plan-sync says not to sync when syncing is switched off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, false, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
}

// Getting this wrong spends somebody's mobile data without asking.
test "plan-sync says not to sync on a cellular connection when the Wi-Fi-only restriction is on" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "cellular", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
}

// Otherwise the restriction would read as "never sync".
test "plan-sync syncs on Wi-Fi when the Wi-Fi-only restriction is on" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(true, result, "shouldRun");
}

// Matching what computeSyncAllowed already does. A platform that cannot tell one connection from another must not be silently
// stopped, which is what the desktop and the browser report.
test "plan-sync syncs when the connection type is unknown and the Wi-Fi-only restriction is on" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "unknown", "{}");

    try expectBool(true, result, "shouldRun");
}

test "plan-sync syncs on a cellular connection when the Wi-Fi-only restriction is off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "cellular", "{}");

    try expectBool(true, result, "shouldRun");
}

test "plan-sync says not to sync when there is no connection" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "none", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
}

test "plan-sync treats a connection type nobody anticipated as unknown rather than stopping syncing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "something-new", "{}");

    try expectBool(true, result, "shouldRun");
}

test "plan-sync says not to sync when no default database has been created yet" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, log, null);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
    try expectString("no database has been opened to sync", result, "reason");
}

// The sync task itself would skip it, having paid for an engine slot and a database open to find that out, and it would do so every
// pass for as long as the phone was switched on.
test "plan-sync says not to sync when the database has no origin to sync to" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, log, DATABASE_PATH);
    try writeDatabaseConfig(&sandbox, null);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
    try expectString("\"photosphere-default\" has no origin to sync to", result, "reason");
}

// Native code runs this step unchanged and builds no payload of its own, so getting it wrong here is getting the background sync
// wrong on both platforms at once.
test "plan-sync hands back a sync-database step for the default database when a sync should run" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(true, result, "shouldRun");
    try expectString(DATABASE_PATH, result, "databasePath");
    try expectKeyStrings(&.{"sync-database"}, "type", result, "steps");
    const stepData = result.object.get("steps").?.array.items[0].object.get("data").?;
    try std.testing.expectEqual(@as(usize, 2), stepData.object.count());
    try expectString(DATABASE_PATH, stepData, "databasePath");

    // Named here rather than in native code, so a phone's job row reads the same as a desktop's. No cancel source: the pass is
    // queued by the native driver under a source the WebView never learns, so the row must not offer a Cancel button it cannot
    // honour.
    try std.testing.expectEqual(@as(usize, 2), at(stepData, "job").?.object.count());
    try expectString("sync:" ++ DATABASE_PATH, stepData, "job.id");
    try expectString("Syncing database", stepData, "job.name");
}

test "plan-sync carries the pause through so the loop waits what the settings asked for" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, 90000);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectInteger(90000, result, "pauseBetweenRunsMs");
}

test "plan-sync's refusal still carries the pause, so the loop does not spin asking again" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, false, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(false, result, "shouldRun");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, result, "pauseBetweenRunsMs");
}

// A sync that overlaps a working prefetch does the same work slowly and gets in its own way: measured on a Pixel 6, reaching the
// origin's merkle tree took 81.5 seconds during such a pass against 97 milliseconds when the phone was idle, and the record merge
// took 15 minutes pulling down the same metadata shards the prefetch was fetching.
test "plan-sync says not to sync while a prefetch is still filling the database in" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"working\"}");

    try expectBool(false, result, "shouldRun");
    try expectContains("prefetch", result, "reason");
    try expectEmptyArray(result, "steps");
}

// The hazard this whole ordering could create, and the reason the wait is bounded by progress rather than by completion. A
// prefetch failed and was never retried on the measured phone; a sync that waited on that would have waited for the life of the
// app, which is a phone that has silently stopped backing up.
test "plan-sync syncs when the prefetch is stalled, so a prefetch that cannot finish cannot stop syncing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"stalled\"}");

    try expectBool(true, result, "shouldRun");
}

test "plan-sync syncs when the prefetch has finished filling the database in" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"complete\"}");

    try expectBool(true, result, "shouldRun");
}

// Nothing has reported a pass, which is every phone at launch. Refusing on no evidence is how a loop gets stuck.
test "plan-sync syncs when nothing is known about the prefetch yet" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"unknown\"}");

    try expectBool(true, result, "shouldRun");
}

// An older native build, or any caller that sends no input data. A missing value must not be able to stop a phone syncing.
test "plan-sync syncs when the native side said nothing about the prefetch at all" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{}");

    try expectBool(true, result, "shouldRun");
}

// A value this build does not recognise, and input data that is not an object at all, are read as nothing known.
test "plan-sync syncs when the prefetch state is a value nobody recognises or the data is not an object" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    try expectBool(true, try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"something-new\"}"), "shouldRun");
    try expectBool(true, try plan(&sandbox, log, "wifi", "{\"prefetchState\":5}"), "shouldRun");
    try expectBool(true, try plan(&sandbox, log, "wifi", "null"), "shouldRun");
}

// The reason a user is most likely to care about is the one the log should carry: a phone with syncing switched off is not syncing
// because it was switched off, whatever the prefetch is doing.
test "plan-sync: the master switch wins over a working prefetch" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, false, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "wifi", "{\"prefetchState\":\"working\"}");

    try expectBool(false, result, "shouldRun");
    try expectContains("switched off", result, "reason");
}

test "plan-sync: the connection check wins over a working prefetch" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "cellular", "{\"prefetchState\":\"working\"}");

    try expectBool(false, result, "shouldRun");
    try expectContains("cellular", result, "reason");
}

test "plan-sync's refusal says why, so a phone that is not syncing can be accounted for" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);

    const result = try plan(&sandbox, log, "cellular", "{}");

    try expectString("the connection is \"cellular\" and syncing is not allowed on it", result, "reason");
}

// The native side cannot tell what connection it has. Treated as unknown it would permit a sync on a connection nobody could
// identify, so the pass fails and says so.
test "plan-sync fails when the host cannot report the connection type" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    const log = MuteLog.init();
    defer sandbox.deinit(log);
    try writeSyncSettings(&sandbox, log, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpSyncableDatabase(&sandbox, log);
    var host: ReportingHost = .{
        .reported = "",
        .failure = error.NoConnectivityManager,
    };

    try std.testing.expectError(error.NoConnectivityManager, planSyncHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), log, try sandbox.json("{}"), sandbox.context(), host.networkStatusHost()));
}
