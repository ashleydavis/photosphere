//
// Tests for plan-prefetch.worker.zig.
//
// Tests for the task the native background prefetch asks what to do.
//
// Every way a pass can be refused is a test here, because each one is a promise the app makes. The
// prefetch fetches from the origin over the user's connection, so it obeys the same settings the
// sync does: the master switch is what a user reaches for when they want the app to stop using their
// data for a database, and the Wi-Fi-only restriction is what stands between filling a replica in and
// somebody's mobile data bill. The rule itself is computeSyncAllowed and is covered in packages/api;
// what is covered here is that this task reads the right settings, asks the platform for the
// connection type, and applies that rule rather than a second copy of it.
//
// It runs against the real filesystem, from a temporary directory standing in for the app's storage
// sandbox, because reading those files (the settings, the database's config, and the merkle tree that
// says whether the replica is partial) is part of what is under test.
//

const std = @import("std");
const test_timers = @import("test-timers.zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
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
const test_environment = @import("../../../node-api-zig/src/test/test-environment.zig");
const fixture_dirs = @import("../../../node-api-zig/src/test/fixture-dirs.zig");
const Sandbox = @import("sandbox.zig").Sandbox;
const ReportingHost = test_hosts.ReportingHost;
const planPrefetchHandler = mobile_worker.plan_prefetch_worker.planPrefetchHandler;
const DEFAULT_SYNC_PAUSE_MS = api.sync_settings.DEFAULT_SYNC_PAUSE_MS;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;
const buildConfigYaml = node_api.config_worker.buildConfigYaml;
const BsonDocument = serialization_zig.bson.BsonDocument;
const at = @import("sandbox.zig").at;

//
// The database the tests use, which stands in for the replica a phone holds.
//
const DATABASE_PATH = "photosphere-default";

//
// Writes the syncing settings into the temporary sandbox's config.yaml, exactly as the app would,
// putting back only the syncing section so whatever automatic import was told to watch survives.
//
fn writeSyncSettings(sandbox: *Sandbox, enabled: bool, onlyOnWifi: bool, pauseBetweenRunsMs: i64) !void {
    const allocator = sandbox.arenaAllocator();
    var config = (try readConfigFromStorage(allocator, sandbox.io, "config.yaml")).config;
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
// Writes the automatic import section naming the database the prefetch falls back to, leaving the
// syncing settings as they are.
//
fn writeDefaultDatabase(sandbox: *Sandbox, defaultDatabasePath: ?[]const u8) !void {
    const allocator = sandbox.arenaAllocator();
    var config = (try readConfigFromStorage(allocator, sandbox.io, "config.yaml")).config;
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
// Writes the database's merkle tree, saying whether the replica is partial.
//
// Written as a real tree through the real saver rather than as a hand-made file, because the flag is
// read back by isDatabasePartial through the real loader: a file this test wrote by hand would prove
// the two agreed with each other and nothing about whether either agrees with the app.
//
fn writeMerkleTree(sandbox: *Sandbox, isPartial: bool) !void {
    const allocator = sandbox.arenaAllocator();
    try std.Io.Dir.cwd().createDirPath(sandbox.io, DATABASE_PATH ++ "/.db");
    const opened = try node_api.open_storage.openStorage(allocator, sandbox.io, DATABASE_PATH, null, null, null);
    // A real UUID, because the tree is serialized by the real saver and it writes the id as sixteen
    // bytes rather than as text.
    var tree = merkle_tree_zig.merkle_tree.createTree("6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d");
    var metadata: BsonDocument = .empty;
    try metadata.put(allocator, "isPartial", .{
        .boolean = isPartial,
    });
    tree.databaseMetadata = metadata;
    tree.merkle = try merkle_tree_zig.merkle_tree.buildMerkleTree(allocator, tree.sort);
    try node_api.tree.saveMerkleTree(allocator, sandbox.io, &tree, opened.storage);
}

//
// Makes every storage this test opens an encrypted one, the way a phone holding a replica of an
// encrypted database has it.
//
// The key goes in through PSI_ENCRYPTION_KEY as a file path, which resolveStorageCredentials accepts
// and which needs neither a vault nor a database list: the point is that the storage is genuinely
// encrypted, not where the key came from. Called before the merkle tree is written, so the tree is
// written encrypted and has to be decrypted to be read back.
// (Zig: the key is the 4096 bit RSA key of encryption-zig's fixtures, because generating one takes hundreds of
// milliseconds, and the environment variable is put back by stopEncryptingEveryStorage.)
//
fn encryptEveryStorage(sandbox: *Sandbox) !void {
    const keyPath = try std.fs.path.join(sandbox.arenaAllocator(), &.{ sandbox.previousCwd, fixture_dirs.KEYS_DIR, "ts-private.pem" });
    try test_environment.setEnv("PSI_ENCRYPTION_KEY", keyPath);
}

//
// Puts back the environment encryptEveryStorage changed (deletes the variable).
//
fn stopEncryptingEveryStorage() void {
    test_environment.setEnv("PSI_ENCRYPTION_KEY", null) catch {
        @panic("The encryption key variable could not be removed after a test.");
    };
}

//
// Sets up everything a prefetch pass needs, so a test only has to change the one thing it is about.
//
fn setUpPartialReplica(sandbox: *Sandbox) !void {
    try writeDefaultDatabase(sandbox, DATABASE_PATH);
    try writeDatabaseConfig(sandbox, "/somewhere/else/photos");
    try writeMerkleTree(sandbox, true);
}

//
// Runs the handler on a host reporting the connection type.
//
fn plan(sandbox: *Sandbox, connectionType: []const u8) !std.json.Value {
    var host: ReportingHost = .{
        .reported = connectionType,
    };
    return planPrefetchHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), .{
        .object = .empty,
    }, sandbox.context(), host.networkStatusHost());
}

// A phone whose settings cannot be read must not start pulling files over whatever connection it happens to have. Off is the only
// safe reading of a file that is not there.
test "plan-prefetch says not to run when there is no settings file at all" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectEmptyArray(result, "steps");
}

// The master switch, and the first thing checked. The prefetch has none of its own on purpose: a user who switches syncing off
// means stop using my data for this database, and there is no reading of that where filling the replica in is still wanted.
test "plan-prefetch says not to run when syncing is switched off" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, false, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectContains("switched off", result, "reason");
    try expectEmptyArray(result, "steps");
}

// A replica of a real library is thousands of thumbnails. Getting this wrong spends somebody's mobile data without asking.
test "plan-prefetch says not to run on a cellular connection when the Wi-Fi-only restriction is on" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "cellular");

    try expectBool(false, result, "shouldRun");
    try expectContains("cellular", result, "reason");
    try expectEmptyArray(result, "steps");
}

test "plan-prefetch runs on Wi-Fi when the Wi-Fi-only restriction is on" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectBool(true, result, "shouldRun");
}

test "plan-prefetch says not to run when no database has been opened" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, null);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectContains("no database", result, "reason");
    try expectString("no database has been opened to fill in", result, "reason");
    try expectEmptyArray(result, "steps");
}

test "plan-prefetch says not to run when the database has no origin to fill in from" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, DATABASE_PATH);
    try writeDatabaseConfig(&sandbox, null);
    try writeMerkleTree(&sandbox, true);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectContains("no origin", result, "reason");
    try expectString("\"photosphere-default\" has no origin to fill in from", result, "reason");
    try expectEmptyArray(result, "steps");
}

// A full database has nothing missing. The prefetch task checks this too and returns, but it would pay for an engine slot and a
// merkle tree load to find out, every pass, for as long as the phone was switched on.
test "plan-prefetch says not to run when the database is not a partial replica" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, DATABASE_PATH);
    try writeDatabaseConfig(&sandbox, "/somewhere/else/photos");
    try writeMerkleTree(&sandbox, false);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectContains("not a partial replica", result, "reason");
    try expectString("\"photosphere-default\" is not a partial replica, so there is nothing to fill in", result, "reason");
    try expectEmptyArray(result, "steps");
}

// The database on a real phone is encrypted, and the merkle tree this reads to find out whether the replica is partial is one of
// the encrypted files. Asked for it without the credentials, the tree loader read .db/files.dat as the raw ciphertext it is on
// disk and threw on the serialized checksum, so every pass of the background loop failed and the prefetch never ran at all.
// Measured on a Pixel 6 against an encrypted S3 origin: "Checksum mismatch: expected <the file's last 32 bytes> got <a hash of
// the rest of it>", once a pass, for as long as the phone was left running.
test "plan-prefetch runs against an encrypted replica, whose merkle tree has to be decrypted to be read" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    defer stopEncryptingEveryStorage();
    try encryptEveryStorage(&sandbox);
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    // The fixture is only worth anything if the tree did go down encrypted, and a wrong key or a key the format cannot read
    // back looks from here exactly like the bug under test.
    const written = try std.Io.Dir.cwd().readFileAlloc(sandbox.io, DATABASE_PATH ++ "/.db/files.dat", sandbox.arenaAllocator(), .unlimited);
    try std.testing.expectEqualStrings("PSEN", written[0..4]);

    const result = try plan(&sandbox, "wifi");

    try expectBool(true, result, "shouldRun");
    try expectString(DATABASE_PATH, result, "databasePath");
    try expectKeyStrings(&.{"prefetch-database"}, "type", result, "steps");
}

// The other half of the encrypted case: the flag is read correctly rather than the read merely not throwing.
test "plan-prefetch says not to run when an encrypted database is not a partial replica" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    defer stopEncryptingEveryStorage();
    try encryptEveryStorage(&sandbox);
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try writeDefaultDatabase(&sandbox, DATABASE_PATH);
    try writeDatabaseConfig(&sandbox, "/somewhere/else/photos");
    try writeMerkleTree(&sandbox, false);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectContains("not a partial replica", result, "reason");
}

// Native code runs this step unchanged and builds no payload of its own, so getting it wrong here is getting the background
// prefetch wrong on both platforms at once.
test "plan-prefetch hands back a prefetch-database step for the database when a pass should run" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectBool(true, result, "shouldRun");
    try expectString(DATABASE_PATH, result, "databasePath");
    try expectKeyStrings(&.{"prefetch-database"}, "type", result, "steps");
    const stepData = result.object.get("steps").?.array.items[0].object.get("data").?;
    try std.testing.expectEqual(@as(usize, 2), stepData.object.count());
    try expectString(DATABASE_PATH, stepData, "databasePath");

    // No cancel source: the pass is queued by the native driver under a source the WebView never learns, so the row must not
    // offer a Cancel button it cannot honour.
    try std.testing.expectEqual(@as(usize, 2), at(stepData, "job").?.object.count());
    try expectString("prefetch:" ++ DATABASE_PATH, stepData, "job.id");
    try expectString("Filling in this database", stepData, "job.name");
}

// The same gap the sync uses, so no new configuration key exists to be kept in step.
test "plan-prefetch carries the pause through so the loop waits what the sync settings asked for" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, 90000);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectInteger(90000, result, "pauseBetweenRunsMs");
}

test "plan-prefetch's refusal still carries the pause, so the loop does not spin asking again" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, false, true, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);

    const result = try plan(&sandbox, "wifi");

    try expectBool(false, result, "shouldRun");
    try expectInteger(DEFAULT_SYNC_PAUSE_MS, result, "pauseBetweenRunsMs");
}

// The native side cannot tell what connection it has. Treated as unknown it would permit a pass on a connection nobody could
// identify, so the pass fails and says so.
test "plan-prefetch fails when the host cannot report the connection type" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try writeSyncSettings(&sandbox, true, false, DEFAULT_SYNC_PAUSE_MS);
    try setUpPartialReplica(&sandbox);
    var host: ReportingHost = .{
        .reported = "",
        .failure = error.NoConnectivityManager,
    };

    try std.testing.expectError(error.NoConnectivityManager, planPrefetchHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), .{
        .object = .empty,
    }, sandbox.context(), host.networkStatusHost()));
}
