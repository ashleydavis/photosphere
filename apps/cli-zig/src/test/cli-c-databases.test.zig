const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");

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
