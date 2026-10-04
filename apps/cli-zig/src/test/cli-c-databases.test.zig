const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const node_utils = @import("node-utils-zig");

//
// The failure paths of the database, secrets, upgrade and info commands that no other test file covers: a subcommand
// run with --yes and a missing required argument, a share that names something which does not exist, a database that
// is not a database and a merkle tree that cannot be read.
//

//
// Gets the absolute path of the built Zig CLI.
//
fn zigCliPath(allocator: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, helpers.psi_path, allocator);
}

//
// Runs the Zig CLI with the arguments.
//
fn runZig(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigCliPath(allocator));
    try argv.appendSlice(allocator, args);
    return helpers.runCli(allocator, argv.items, environment);
}

//
// Expects the CLI to exit with the code and write the output.
//
fn expectResult(result: helpers.CliResult, expectedStdout: []const u8, expectedStderr: []const u8, expectedExitCode: u8) !void {
    try std.testing.expectEqualStrings(expectedStdout, result.stdout);
    try std.testing.expectEqualStrings(expectedStderr, result.stderr);
    try std.testing.expectEqual(expectedExitCode, result.exitCode);
}

//
// The note `dbs send`, `dbs receive`, `secrets send` and `secrets receive` print under the ℹ Network Requirement
// heading: a 70 wide box (the blank lines are 70 spaces, which a multi-line string literal cannot carry).
//
const network_note = "   \u{2139} Network Requirement\n" ++ (" " ** 70) ++ "\n" ++
    "   Both devices must be on the same local network (wired or Wi-Fi).   \n" ++
    "   This does not work over the internet." ++ (" " ** 30) ++ "\n" ++
    (" " ** 70) ++ "\n";

//
// The databases of the dbs tests: one local path with every secret set and one S3 path with none.
//
const seed_config =
    \\recent_database_names = [ "photos" ]
    \\
    \\[[databases]]
    \\name = "photos"
    \\description = "My photos"
    \\path = "/data/photos"
    \\origin = "s3:bucket:/x"
    \\s3_key = "s3a"
    \\encryption_key = "my-key"
    \\geocoding_key = "geo"
    \\
    \\[[databases]]
    \\name = "my-db"
    \\description = ""
    \\path = "s3:bucket/db"
    \\
;

//
// The plaintext vault holding the secrets seed_config names.
//
const seed_vault =
    \\{"s3a":{"name":"s3a","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}"},"my-key":{"name":"my-key","type":"encryption-key","value":"PEM"},"geo":{"name":"geo","type":"api-key","value":"geo-value"}}
;

//
// Creates a test root whose config holds the databases given (seed_config, or an empty list when it is null) and
// whose plaintext vault holds seed_vault, and returns its environment.
//
fn setup(allocator: std.mem.Allocator, root: []const u8, databasesConfig: ?[]const u8) !*std.process.Environ.Map {
    const environment = try helpers.cliEnvironment(allocator, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/config/databases.toml", .{root}),
        .data = databasesConfig orelse "databases = []\nrecent_database_names = []\n",
    });
    // The plaintext vault keeps vault.json in the directory PHOTOSPHERE_VAULT_DIR names, which is the test root
    // itself (a directory of its own under the root would have to be created first, and this test needs no other).
    try environment.put("PHOTOSPHERE_VAULT_DIR", root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/vault.json", .{root}),
        .data = seed_vault,
    });
    return environment;
}

test "info classifyInput tells an asset id and a hash from a path" {
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9-a652-4047-b869-1154bf2c95a1"), .assetId);
    try std.testing.expectEqual(cli.info.classifyInput("89171CD9-A652-4047-B869-1154BF2C95A1"), .assetId);
    try std.testing.expectEqual(cli.info.classifyInput("426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c"), .hash);
    try std.testing.expectEqual(cli.info.classifyInput("426FAB8DBDD88EAD05220E0A73644B1D77C4591689701090926129AF8BA45E7C"), .hash);

    // A path is anything else: a wrong length, a hex character where a dash belongs, and a non-hex character of the
    // right length are all paths.
    try std.testing.expectEqual(cli.info.classifyInput(""), .path);
    try std.testing.expectEqual(cli.info.classifyInput("/data/photos/test.png"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9-a652-4047-b869-1154bf2c95a"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("g9171cd9-a652-4047-b869-1154bf2c95a1"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9+a652-4047-b869-1154bf2c95a1"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9-a652-4047-b869-1154bf2c95a1a"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("z26fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c"), .path);
}

//
// Tells whether the path exists.
//
fn pathExistsAt(directory: []const u8, relative: []const u8) bool {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ directory, relative }) catch return false;
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

//
// Expects the text to appear in the output.
//
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("the output does not hold the expected text:\n{s}\n", .{haystack});
        return error.TestExpectedEqual;
    }
}

test "secrets clear --yes deletes every secret and reports how many" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-clear");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "clear", "--yes" }), "\n\u{2713} Deleted 3 secret(s).\n", "", 0);

    // Every secret is gone, so the list is empty and a second clear has nothing to do.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "clear", "--yes" }), "No secrets found.\n", "", 0);
}

test "secrets send with an empty vault says there is nothing to send and opens no socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-send-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "send", "--yes" }), "\nSend Secret\n" ++ network_note ++ "No secrets found.\nUse \"psi secrets add\" to add a secret first.\n", "", 0);
}

test "secrets import --yes stores a key file under its name without the .key extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-import");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);
    const keyFile = try std.fmt.allocPrint(allocator, "{s}/mykey.key", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = keyFile, .data = "PEM-BODY" });

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "import", "--yes", "--private-key", keyFile }), "\u{2713} Key imported as \"mykey\".\n", "", 0);

    // The key is an encryption-key secret named after the file, and the vault still holds the three it started with.
    try expectContains((try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "mykey" })).stdout, "Type: encryption-key\nValue: PEM-BODY\n");
    try expectContains((try runZig(allocator, environment, &.{ "secrets", "list" })).stdout, "my-key   ");
}

test "debug build-sort-index lists, drops and rebuilds the indexes of a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-sort-index");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", db);

    // The v6 fixture carries both indexes, so the found/deleted counts take their plural branch.
    try expectResult(try runZig(allocator, environment, &.{ "debug", "build-sort-index", "--db", db, "--yes" }), try std.fmt.allocPrint(allocator,
        \\
        \\🔨 Rebuilding Sort Indexes
        \\  Database: {s}
        \\
        \\Found 2 existing sort indexes:
        \\  - hash (asc)
        \\  - photoDate (desc)
        \\
        \\Deleted 2 sort indexes.
        \\
        \\Rebuilding sort indexes...
        \\
        \\✅ Sort indexes rebuilt successfully.
        \\
        \\Rebuilt indexes:
        \\  - hash (asc, string)
        \\  - photoDate (desc, date)
        \\
        \\
    , .{db}), "", 0);
}

test "debug build-files-tree rebuilds the tree from the files on storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-files-tree");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/no-assets", db);

    // The only file the no-assets fixture holds is its README, so the count is one.
    try expectResult(try runZig(allocator, environment, &.{ "debug", "build-files-tree", "--db", db, "--yes" }), try std.fmt.allocPrint(allocator,
        \\
        \\Rebuilding files merkle tree from storage
        \\  Database: {s}
        \\
        \\Rebuilt files merkle tree: 1 files.
        \\
        \\
    , .{db}), "", 0);
}

test "debug build-files-tree and debug merkle-tree refuse a directory that is not a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-not-a-db");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, db);

    // Both commands say the same thing. The temp directory they leave behind carries a UUID of its own, so only the
    // part before it is compared.
    for ([_][]const []const u8{
        &.{ "debug", "build-files-tree", "--db", db, "--yes" },
        &.{ "debug", "merkle-tree", "--db", db, "--yes" },
    }) |args| {
        const result = try runZig(allocator, environment, args);
        try std.testing.expectEqual(@as(u8, 1), result.exitCode);
        try expectContains(result.stdout, try std.fmt.allocPrint(allocator,
            \\
            \\✗ No database found at: {s}
            \\  The database directory must contain a ".db" folder with files.dat or tree.dat.
            \\
            \\To create a new database at this directory, use:
            \\  psi init --db {s}
            \\Temporary files retained for inspection:
        , .{ db, db }));
    }
}

test "debug remove-duplicates names the input file it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-rm-dupes");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", db);

    // With no --input the duplicates report is read from <db>/duplicates.json, which this database does not have.
    // The path is joined with the separator of the platform, which is a `\` on Windows, so it is joined here too
    // rather than written with a `/` into a format string.
    const inputFile = try node_utils.path.join(allocator, &.{ db, "duplicates.json" });
    const result = try runZig(allocator, environment, &.{ "debug", "remove-duplicates", "--db", db, "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try expectContains(result.stdout, try std.fmt.allocPrint(allocator, "Error: Failed to read input file {s}: ENOENT: no such file or directory, open ", .{inputFile}));
}

test "dbs view prints the entry of a database and (none) for every field it does not have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-view");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "view", "--yes", "--name", "my-db" }),
        \\
        \\Database Entry
        \\──────────────────────────────────────────────────
        \\Name:        my-db
        \\Description: (none)
        \\Path:        s3:bucket/db
        \\S3 Creds:    (none)
        \\Encryption:  (none)
        \\Geocoding:   (none)
        \\
        \\
    , "", 0);

    // The database that has every field set names all three secrets.
    try expectContains((try runZig(allocator, environment, &.{ "dbs", "view", "--yes", "--name", "photos" })).stdout, "S3 Creds:    s3a\nEncryption:  my-key\nGeocoding:   geo\n");
}

test "dbs add stores the database and refuses a secret that is not in the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-add");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "add", "--yes", "--name", "x", "--path", "s3:bucket/y" }), "\u{2713} Database \"x\" added.\n", "", 0);
    try expectContains((try runZig(allocator, environment, &.{ "dbs", "list" })).stdout, "x" ++ (" " ** 25) ++ "s3:bucket/y\n");

    // A secret the vault does not hold is refused and nothing is stored.
    try std.testing.expect((try runZig(allocator, environment, &.{ "dbs", "add", "--yes", "--name", "y", "--path", "s3:bucket/z", "--encryption-key", "missing-key" })).exitCode != 0);
    try std.testing.expect(std.mem.indexOf(u8, (try runZig(allocator, environment, &.{ "dbs", "list" })).stdout, "s3:bucket/z") == null);
}

test "dbs remove --yes reports the database it removed and the one it could not find" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-remove");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "remove", "--yes", "--name", "my-db" }), "\n\u{2713} Database \"my-db\" removed from list.\n", "", 0);
    try std.testing.expectEqual(@as(u8, 1), (try runZig(allocator, environment, &.{ "dbs", "remove", "--yes", "--name", "my-db" })).exitCode);
}

test "secrets view prints the fields of a secret and secrets remove deletes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-view");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    // An s3-credentials secret is JSON, so its value is printed one field per line.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "s3a" }),
        \\
        \\Name: s3a
        \\Type: s3-credentials
        \\Value:
        \\  region: us-east-1
        \\  accessKeyId: AK
        \\  secretAccessKey: SK
        \\
        \\
    , "", 0);

    try expectContains((try runZig(allocator, environment, &.{ "secrets", "remove", "--yes", "--name", "s3a" })).stdout, "\u{2713} Secret \"s3a\" deleted.\n");
    try std.testing.expectEqual(@as(u8, 1), (try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "s3a" })).exitCode);
}

test "upgrade takes a v5 database all the way to the current version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-upgrade-v5");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v5", db);

    const result = try runZig(allocator, environment, &.{ "upgrade", "--db", db, "--yes" });
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);

    // The backup instructions are the only warnings, and they name the directory this run was given. The command
    // it suggests is `xcopy` on Windows and `cp -r` everywhere else, and it joins the path with the separator of
    // the platform, which is a `\` on Windows.
    const backupCommand = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(allocator, "xcopy \"{s}\" \"{s}-backup\" /E /I\n", .{ db, db })
    else
        try std.fmt.allocPrint(allocator, "cp -r \"{s}\" \"{s}-backup\"\n", .{ db, db });
    try expectContains(result.stderr, backupCommand);

    // The version is read before anything is changed, the old metadata/ directory is migrated and removed, and the
    // tree is written to .db/files.dat. The error log line that follows names a file of its own, so the output is
    // compared up to it.
    try expectContains(result.stdout, try std.fmt.allocPrint(allocator,
        \\
        \\Upgrading media file database...
        \\✓ Found database version 5
        \\
        \\✓ Non-interactive mode: proceeding with database upgrade
        \\Upgrading database from version 5 to version 6...
        \\Migrating BSON from metadata/ to .db/bson/.
        \\✓ BSON migrated to .db/bson/
        \\Rebuilding BSON database merkle tree.
        \\✓ BSON database merkle tree built successfully
        \\Rebuilding sort indexes.
        \\✓ Sort indexes rebuilt successfully
        \\✓ Removed metadata/ directory
        \\✓ Created .db/config.json
        \\✓ Database upgraded successfully to version 6
        \\
        \\Next steps:
        \\    # View database summary and tree hash
        \\    psi summary --db {s}
        \\
        \\    # Verify the integrity of the upgraded database
        \\    psi verify --db {s}
        \\
    , .{ db, db }));

    // The database really did move: metadata/ is gone and .db/files.dat is there.
    try std.testing.expect(!pathExistsAt(db, "metadata"));
    try std.testing.expect(pathExistsAt(db, ".db/files.dat"));
}

test "dbs view prints the origin of a database that has one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-view-origin");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "view", "--yes", "--name", "photos" }),
        \\
        \\Database Entry
        \\──────────────────────────────────────────────────
        \\Name:        photos
        \\Description: My photos
        \\Path:        /data/photos
        \\S3 Creds:    s3a
        \\Encryption:  my-key
        \\Geocoding:   geo
        \\Origin:      s3:bucket:/x
        \\
        \\
    , "", 0);
}

test "dbs view, edit and remove say the same thing about a database that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-nodb");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    // The name is close to "photos", so all three suggest it before they exit, and none of them writes the error to
    // stdout. `dbs view` and `dbs remove` share one message; `dbs edit` has its own that names the database.
    for ([_][]const []const u8{
        &.{ "dbs", "view", "--yes", "--name", "photo" },
        &.{ "dbs", "remove", "--yes", "--name", "photo" },
    }) |args| {
        try expectResult(try runZig(allocator, environment, args), "Did you mean:\n  \u{2022} photos\n", "\u{2717} No database matching the given name or path was found.\n", 1);
    }
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "edit", "--yes", "--name", "photo" }), "Did you mean:\n  \u{2022} photos\n", "\u{2717} No database named \"photo\" found.\n", 1);
}

test "dbs add refuses a secret that is not in the vault and stores nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-add-badkey");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    const result = try runZig(allocator, environment, &.{ "dbs", "add", "--yes", "--name", "y", "--path", "s3:bucket/z", "--encryption-key", "missing-key" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try expectContains(result.stderr, "\u{2717} Encryption key \"missing-key\" not found in vault.\n");
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, (try runZig(allocator, environment, &.{ "dbs", "list" })).stdout, "s3:bucket/z") == null);
}

test "dbs edit changes a field and clear empties the list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-edit");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "edit", "--yes", "--name", "my-db", "--description", "New" }), "\u{2713} Database \"my-db\" updated.\n", "", 0);
    try expectContains((try runZig(allocator, environment, &.{ "dbs", "view", "--yes", "--name", "my-db" })).stdout, "Description: New\n");

    // Clearing reports how many databases it removed, and a second clear has nothing left to do.
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "clear", "--yes" }), "\n\u{2713} Removed 2 database(s) from the list.\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "clear", "--yes" }), "No databases configured.\n", "", 0);
}

test "secrets view and secrets remove report a secret that is not in the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-nosecret");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    // Nothing is close enough to "nope" to suggest, so the error stands alone; "s3b" is close to "s3a".
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "nope" }), "", "\u{2717} No secret named \"nope\" found.\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "remove", "--yes", "--name", "s3b" }), "Did you mean:\n  \u{2022} s3a\n  \u{2022} geo\n", "\u{2717} No secret named \"s3b\" found.\n", 1);
}

test "dbs subcommands run with --yes and no argument say which argument they need" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-yes");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "add", "--yes" }), "", "\u{2717} --name and --path are required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "add", "--yes", "--name", "photos" }), "", "\u{2717} --name and --path are required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "view", "--yes" }), "", "\u{2717} --name or --path is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "edit", "--yes" }), "", "\u{2717} --name is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "remove", "--yes" }), "", "\u{2717} --name or --path is required with --yes\n", 1);

    // An empty option is not a value: --name "" is as missing as no --name at all.
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "view", "--yes", "--name", "" }), "", "\u{2717} --name or --path is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "add", "--yes", "--name", "", "--path", "/data/photos" }), "", "\u{2717} --name and --path are required with --yes\n", 1);

    // `dbs receive --yes` needs the pairing code before it opens the socket, so it says so and exits.
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "receive", "--yes" }), "\nReceive Database\n" ++ network_note ++ "Hint: Run `psi dbs send` on another device to send a database.\n", "\u{2717} --code is required with --yes\n", 1);
}

test "secrets subcommands run with --yes and no argument say which argument they need" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-yes");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes" }), "", "\u{2717} --name is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes" }), "", "\u{2717} --name is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "remove", "--yes" }), "", "\u{2717} --name is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "import", "--yes" }), "", "\u{2717} --private-key is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "x", "--type", "plain" }), "", "\u{2717} --name, --type, and --value are required with --yes\n", 1);

    // `secrets receive --yes` needs the pairing code before it opens the socket, so it says so and exits.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "receive", "--yes" }), "\nReceive Secret\n" ++ network_note ++ "Hint: Run `psi secrets send` on another device to send a secret.\n", "\u{2717} --code is required with --yes\n", 1);
}

test "secrets add and edit refuse a bad type, a name in the vault, an empty change and a missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-refuse");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing.pem", .{root});

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "new", "--type", "bogus", "--value", "v" }), "", "\u{2717} Invalid secret type \"bogus\". Must be one of: api-key, s3-credentials, encryption-key, plain\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "s3a", "--type", "plain", "--value", "v" }), "", "\u{2717} A secret named \"s3a\" already exists. Use \"secrets edit\" to update it.\n", 1);

    // Editing a secret that exists but changing nothing, and pointing at a file that is not there.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "s3a" }), "", "\u{2717} --new-name, --value, or --value-file is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "s3a", "--value-file", missing }), "", try std.fmt.allocPrint(allocator, "\u{2717} File not found: {s}\n", .{missing}), 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "import", "--yes", "--private-key", missing }), "", try std.fmt.allocPrint(allocator, "\u{2717} File not found: {s}\n", .{missing}), 1);

    // Nothing was stored and nothing was deleted: the vault still holds exactly the three secrets it started with.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "list" }), "\nName                                     Type                 Value\n" ++ ("\u{2500}" ** 80) ++ "\ns3a                                      s3-credentials       ****\nmy-key                                   encryption-key       ****\ngeo                                      api-key              ****\n\n", "", 0);
}

test "dbs send says there is nothing to send when no database is configured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-send-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, null);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "send", "--yes" }), "\nSend Database\n" ++ network_note ++ "No databases configured.\nUse \"psi dbs add\" to add a database first.\n", "", 0);
}

test "dbs send refuses a database that does not exist before it opens the socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-send-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "send", "--yes", "--name", "photos2" }), "\nSend Database\n" ++ network_note ++ "Did you mean:\n  \u{2022} photos\n", "\u{2717} No database matching the given name or path was found.\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "dbs", "send", "--yes", "--path", "/data/photos2" }), "\nSend Database\n" ++ network_note, "\u{2717} No database matching the given name or path was found.\n", 1);
}

test "secrets send refuses a secret that does not exist before it opens the socket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-send-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "send", "--yes", "--name", "s3b" }), "\nSend Secret\n" ++ network_note ++ "Did you mean:\n  \u{2022} s3a\n  \u{2022} geo\n", "\u{2717} No secret named \"s3b\" found.\n", 1);
}

test "upgrade refuses a directory that is not a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-upgrade-nodb");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const notADatabase = try std.fmt.allocPrint(allocator, "{s}/not-a-database", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, notADatabase);

    const result = try runZig(allocator, environment, &.{ "upgrade", "--db", notADatabase, "--yes" });
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "\nUpgrading media file database...\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, try std.fmt.allocPrint(allocator, "\u{2717} No database found at: {s}\n", .{notADatabase})) != null);
}

test "upgrade reports a merkle tree it cannot read and changes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-upgrade-corrupt");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", db);

    // A files.dat cut off after its magic and one length reads as a node length of 1163023430 bytes, so loadTree
    // cannot return a tree and the version of the database cannot be read.
    const filesDat = try std.fmt.allocPrint(allocator, "{s}/.db/files.dat", .{db});
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, filesDat, allocator, .unlimited);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = filesDat, .data = contents[0..12] });

    const result = try runZig(allocator, environment, &.{ "upgrade", "--db", db, "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "\nUpgrading media file database...\n\n"));
    // The failure is reported, not swallowed: the retry gives up and the error names the file it could not read.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Operation failed, no more retries allowed.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Cannot read") != null);
    // The database was not upgraded, so nothing claims it moved forward from a version.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Found database version") == null);
    try std.testing.expectEqualStrings(contents[0..12], try std.Io.Dir.cwd().readFileAlloc(std.testing.io, filesDat, allocator, .unlimited));
}

//
// How many seconds the share commands wait for a peer in the tests where nobody ever turns up, given to `--timeout` so
// the branch is taken after a second rather than after the default minute.
//
const share_discovery_timeout = "1";

//
// How many seconds the sender of the pairing-code-rejected tests waits. Unlike the no-peer tests this one has to be
// long enough for the receiver's announcements to reach the sender, since the sender only knows the code was rejected
// once it has read one that does not match. The receiver announces every second, so this covers several of them.
//
const mismatched_receiver_timeout = "4";

//
// How many seconds the receiving `psi` of the pairing-code-rejected tests waits. It outlives the sender, and the test
// kills it when it is done, so it never decides how long the test takes.
//
const held_receiver_timeout = "60";

test "dbs receive says no device connected when no sender turns up before the discovery timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-receive-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "receive", "--yes", "--code", "1234", "--timeout", share_discovery_timeout }),
        "\nReceive Database\n" ++ network_note ++
            "Hint: Run `psi dbs send` on another device to send a database.\n" ++
            "Waiting for sender on the local network... (Ctrl+C to cancel)\n" ++
            "No device connected within 1 seconds.\n", "", 0);
}

test "secrets receive says no sender connected when no sender turns up before the discovery timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-receive-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "receive", "--yes", "--code", "1234", "--timeout", share_discovery_timeout }),
        "\nReceive Secret\n" ++ network_note ++
            "Hint: Run `psi secrets send` on another device to send a secret.\n" ++
            "Waiting for sender on the local network... (Ctrl+C to cancel)\n" ++
            "No sender connected within 1 seconds.\n", "", 0);
}

test "dbs send says no device found when no receiver turns up before the discovery timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-send-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "send", "--yes", "--name", "my-db", "--code", "1234", "--timeout", share_discovery_timeout }),
        "\nSend Database\n" ++ network_note ++
            "\nDatabase to send:\n" ++
            "  Name:        my-db\n" ++
            "  Description: (none)\n" ++
            "  Path:        s3:bucket/db\n" ++
            "\n" ++
            "\n" ++
            "  Pairing code: 1234\n" ++
            "  Enter this code on the other device, then wait.\n" ++
            "\n" ++
            "Waiting for other device on local network... (Ctrl+C to cancel)\n" ++
            "No device found within 1 seconds.\n", "", 0);
}

test "secrets send says no receiver found when no receiver turns up before the discovery timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-send-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "send", "--yes", "--name", "s3a", "--code", "1234", "--timeout", share_discovery_timeout }),
        "\nSend Secret\n" ++ network_note ++
            "Hint: Run `psi secrets receive` on another device to receive this secret.\n" ++
            "\n" ++
            "Secret to send:\n" ++
            "  Name: s3a\n" ++
            "  Type: s3-credentials\n" ++
            "\n" ++
            "  Pairing code: 1234\n" ++
            "  Enter this code on the receiver device, then wait.\n" ++
            "\n" ++
            "Waiting for receiver on the local network... (Ctrl+C to cancel)\n" ++
            "No receiver found within 1 seconds.\n", "", 0);
}

//
// Draws a 4-digit pairing code. Discovery is machine-wide, so the codes are drawn per run: two fixed
// ones could pair a sender in one run with a receiver in another.
//
fn randomPairingCode(allocator: std.mem.Allocator) ![]const u8 {
    var randomBytes: [4]u8 = undefined;
    std.testing.io.random(&randomBytes);
    return std.fmt.allocPrint(allocator, "{d}", .{1000 + std.mem.readInt(u32, &randomBytes, .little) % 9000});
}

test "dbs send tells a mistyped pairing code from an absent device" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-dbs-send-mismatch");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);
    const code = try randomPairingCode(allocator);
    const otherCode = try randomPairingCode(allocator);

    // The receiver announces a code that is not the sender's, which is the mistyped case: a device
    // was found, and it is not waiting for this share. Saying "no device found" here would send the
    // user looking for a device that is sitting right there.
    var receiver = try helpers.startCliAndWaitFor(allocator, &.{ try zigCliPath(allocator), "dbs", "receive", "--yes", "--code", otherCode, "--timeout", held_receiver_timeout }, environment, "Waiting for sender on the local network...");
    defer receiver.kill(std.testing.io);

    try expectResult(try runZig(allocator, environment, &.{ "dbs", "send", "--yes", "--name", "my-db", "--code", code, "--timeout", mismatched_receiver_timeout }), try std.mem.concat(allocator, u8, &.{
        "\nSend Database\n",
        network_note,
        "\nDatabase to send:\n",
        "  Name:        my-db\n",
        "  Description: (none)\n",
        "  Path:        s3:bucket/db\n",
        "\n",
        "\n",
        try std.fmt.allocPrint(allocator, "  Pairing code: {s}\n", .{code}),
        "  Enter this code on the other device, then wait.\n",
        "\n",
        "Waiting for other device on local network... (Ctrl+C to cancel)\n",
        "Pairing code rejected: a device was found but it is using a different code.\n",
    }), "", 0);
}

test "secrets send tells a mistyped pairing code from an absent device" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "clic-secrets-send-mismatch");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setup(allocator, root, seed_config);
    const code = try randomPairingCode(allocator);
    const otherCode = try randomPairingCode(allocator);

    var receiver = try helpers.startCliAndWaitFor(allocator, &.{ try zigCliPath(allocator), "secrets", "receive", "--yes", "--code", otherCode, "--timeout", held_receiver_timeout }, environment, "Waiting for sender on the local network...");
    defer receiver.kill(std.testing.io);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "send", "--yes", "--name", "s3a", "--code", code, "--timeout", mismatched_receiver_timeout }), try std.mem.concat(allocator, u8, &.{
        "\nSend Secret\n",
        network_note,
        "Hint: Run `psi secrets receive` on another device to receive this secret.\n",
        "\n",
        "Secret to send:\n",
        "  Name: s3a\n",
        "  Type: s3-credentials\n",
        "\n",
        try std.fmt.allocPrint(allocator, "  Pairing code: {s}\n", .{code}),
        "  Enter this code on the receiver device, then wait.\n",
        "\n",
        "Waiting for receiver on the local network... (Ctrl+C to cancel)\n",
        "Pairing code rejected: a device was found but it is using a different code.\n",
    }), "", 0);
}
