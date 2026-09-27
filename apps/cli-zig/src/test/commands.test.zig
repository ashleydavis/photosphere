const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("test-helpers.zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");

//
// The expected output of these tests is written out here, ported from the TypeScript CLI: the report text from
// apps/cli/src/cmd/<command>.ts, the "No database found" and "not empty" messages from apps/cli/src/lib/init-cmd.ts,
// the worker log prefix from apps/cli/src/lib/worker-log-bun.ts and the numbers from the files of test/dbs/v6.
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
// Creates a test root with a copy of test/dbs/v6 in <root>/db.
//
fn setup(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const root = try helpers.makeTempDir(allocator, name);
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", try std.fmt.allocPrint(allocator, "{s}/db", .{root}));
    return root;
}

//
// Replaces the task IDs of worker log prefixes (`[W1:<uuid>]`) with a placeholder (task IDs are random).
//
fn normalizeTaskIds(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[' and index + 2 < text.len and text[index + 1] == 'W') {
            var position = index + 2;
            while (position < text.len and std.ascii.isDigit(text[position])) {
                position += 1;
            }
            if (position + 38 <= text.len and text[position] == ':' and text[position + 37] == ']') {
                try result.appendSlice(allocator, text[index .. position + 1]);
                try result.appendSlice(allocator, "<task>]");
                index = position + 38;
                continue;
            }
        }
        try result.append(allocator, text[index]);
        index += 1;
    }
    return result.items;
}

//
// Replaces the session directory of the "Temporary files retained for inspection: <dir>" line, which ends with
// the random session id.
//
fn maskRetainedSessionDir(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const label = "Temporary files retained for inspection: ";
    const start = std.mem.indexOf(u8, text, label) orelse {
        return text;
    };
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.concat(allocator, u8, &.{ text[0 .. start + label.len], "<session dir>", text[end..] });
}

//
// Replaces every occurrence of a path in the output.
//
fn normalize(allocator: std.mem.Allocator, result: helpers.CliResult, path: []const u8, placeholder: []const u8) !helpers.CliResult {
    return .{
        .exitCode = result.exitCode,
        .stdout = try normalizeTaskIds(allocator, try std.mem.replaceOwned(u8, allocator, result.stdout, path, placeholder)),
        .stderr = try normalizeTaskIds(allocator, try std.mem.replaceOwned(u8, allocator, result.stderr, path, placeholder)),
    };
}

//
// The "Next steps" verifyCommand (apps/cli/src/cmd/verify.ts) prints for a database without problems, <db>
// standing for the database path.
//
const verify_next_steps_healthy =
    \\Next steps:
    \\    # Create a backup copy of your database
    \\    psi replicate --db <db> --dest <other-db-path>
    \\
    \\    # Synchronize changes between two databases that have been independently changed
    \\    psi sync --db <db> --dest <other-db-path>
    \\
    \\    # Compare this database with another location
    \\    psi compare --db <db> --dest <other-db-path>
    \\
    \\    # View database summary and tree hash
    \\    psi summary
    \\
;

//
// The report of `psi verify` for test/dbs/v6. Its files tree holds README.md (913 bytes) and the asset, display
// and thumb files of its one asset (2,049,800 + 696,014 + 130,591 bytes): 4 files, 2,877,318 bytes, which
// formatBytes (apps/cli/src/lib/format.ts) prints as 2.74 MiB, and a tree of 7 nodes. verifyDatabaseFiles
// (packages/node-api/src/lib/verify.ts) checks files.dat, collection.dat, the 2 shard files and the 4 sort index
// files: 8 files, 363,161 bytes, printed as 355 KiB.
//
const verify_v6_report =
    \\Asset files verified.
    \\
    \\Files imported:    1
    \\Total files:       4
    \\Total size:        2.74 MiB
    \\Files processed:   4
    \\Nodes processed:   7
    \\Unmodified:        4
    \\Modified:          0
    \\New:               0
    \\Removed:           0
    \\Failures:          0
    \\Record mismatches: 0
    \\
    \\Database files:
    \\  Total files:    8
    \\  Total size:     355 KiB
    \\  Valid files:    8
    \\  Invalid files:  0
    \\
    \\✅ Database verification passed - all files are intact
    \\
++ "\n" ++ verify_next_steps_healthy;

//
// The report of `psi verify --full --path asset` for test/dbs/v6: only the asset file matches the path, and a
// verification of a path skips the database files.
//
const verify_v6_asset_path_report =
    \\Verified files matching: asset
    \\
    \\Files imported:    1
    \\Total files:       4
    \\Total size:        2.74 MiB
    \\Files processed:   1
    \\Nodes processed:   7
    \\Unmodified:        1
    \\Modified:          0
    \\New:               0
    \\Removed:           0
    \\Failures:          0
    \\Record mismatches: 0
    \\
    \\✅ Database verification passed - all files are intact
    \\
++ "\n" ++ verify_next_steps_healthy;

test "verify prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-verify");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--yes" }), db, "<db>");
    try expectResult(result, verify_v6_report, "", 0);

    const fullResult = try normalize(allocator, try runZig(allocator, environment, &.{ "ver", "--db", db, "--yes", "--full", "--path", "asset" }), db, "<db>");
    try expectResult(fullResult, verify_v6_asset_path_report, "", 0);
}

//
// The report of summaryCommand (apps/cli/src/cmd/summary.ts) for test/dbs/v6 at <db>: its files tree holds 4 files
// (2.74 MiB) from 1 import and is a version 6 tree. {files}, {database} and {full} stand for the root hashes.
//
const summary_v6_report =
    \\
    \\📊 Database Summary
    \\
    \\Mode:             full
    \\Files imported:   1
    \\Total files:      4
    \\Total size:       2.74 MiB
    \\Database version: 6
    \\Files hash:       {files}
    \\Database hash:    {database}
    \\Full root hash:   {full}
    \\
    \\Next steps:
    \\    # Verify the integrity of all files in the database
    \\    psi verify
    \\
    \\    # Add more files to your database
    \\    psi add <paths>
    \\
    \\    # Create a backup copy of your database
    \\    psi replicate --db <db> --dest <path>
    \\
    \\    # Synchronize changes between two databases that have been independently changed
    \\    psi sync --db <db> --dest <path>
    \\
;

test "summary prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-summary");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // The root hashes the TypeScript implementation stored in the database's trees, and their combination.
    const storage = try storage_zig.storage_factory.createStorage(allocator, std.testing.io, db, null, null);
    const filesTree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, std.testing.io, ".db/files.dat", storage.storage, "FTRE")).?;
    const databaseHash = (try @import("bdb-zig").merkle_tree.getDatabaseRootHash(allocator, std.testing.io, storage.storage, ".db/bson")).?;
    const fullHash = merkle_tree_zig.merkle_tree.combineHashes(filesTree.merkle.?.hash, databaseHash);
    var expected = try std.mem.replaceOwned(u8, allocator, summary_v6_report, "{files}", try std.fmt.allocPrint(allocator, "{x}", .{filesTree.merkle.?.hash}));
    expected = try std.mem.replaceOwned(u8, allocator, expected, "{database}", try std.fmt.allocPrint(allocator, "{x}", .{databaseHash}));
    expected = try std.mem.replaceOwned(u8, allocator, expected, "{full}", try std.fmt.allocPrint(allocator, "{x}", .{&fullHash}));

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "summary", "--db", db, "--yes" }), db, "<db>");
    try expectResult(result, expected, "", 0);

    const aliasResult = try normalize(allocator, try runZig(allocator, environment, &.{ "sum", "--db", db, "--yes" }), db, "<db>");
    try expectResult(aliasResult, expected, "", 0);
}

//
// The report of listCommand (apps/cli/src/cmd/list.ts) for test/dbs/v6: its photoDate sort index holds one asset.
// {encryption} stands for the encryption status of the asset file.
//
const list_v6_report =
    \\
    \\📁 Database Files
    \\
    \\Files are sorted by date (newest first).
    \\
    \\--- Page 1 ---
    \\89171cd9-a652-4047-b869-1154bf2c95a1 test.jpg
    \\  Date: 5/27/2025 | Size: Unknown | Type: image/jpeg | 2560×1920
    \\  Encryption: {encryption}
    \\  Path: ../../test
    \\
    \\
    \\End of results. Displayed 1 files total.
    \\
;

test "list prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-list");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const expected = try std.mem.replaceOwned(u8, allocator, list_v6_report, "{encryption}", "unencrypted");
    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--yes" }), expected, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "ls", "--db", db, "--yes" }), expected, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "l", "--db", db, "--page-size", "1", "--yes" }), expected, "", 0);

    // A page size that is not a number shows an empty page (TypeScript: `records.slice(0, NaN)`).
    const emptyPage =
        \\
        \\📁 Database Files
        \\
        \\Files are sorted by date (newest first).
        \\
        \\--- Page 1 ---
        \\
        \\End of results. Displayed 0 files total.
        \\
    ;
    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--page-size", "abc", "--yes" }), emptyPage, "", 0);

    // An asset file that starts with a new format encryption header shows the hash of its public key.
    var header: [44 + 4]u8 = undefined;
    @memcpy(header[0..12], "PSEN\x01\x00\x00\x00A2CB");
    @memset(header[12..44], 0xab);
    @memcpy(header[44..48], "rest");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/asset/89171cd9-a652-4047-b869-1154bf2c95a1", .{db}), .data = &header });
    const encrypted = try std.mem.replaceOwned(u8, allocator, list_v6_report, "{encryption}", "encrypted (key: abababababababababababababababababababababababababababababababab)");
    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--yes" }), encrypted, "", 0);
}

//
// The report of infoCommand (apps/cli/src/cmd/info.ts) for test/dbs/v6's asset looked up by hash, by ID and by an
// ID that is not in the database.
//
const info_v6_report =
    \\
    \\Info for 3 item(s):
    \\
    \\📁 Hash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c
    \\   Asset ID: 89171cd9-a652-4047-b869-1154bf2c95a1
    \\   Original file: test.jpg
    \\   Original path: ../../test
    \\   Type: image/jpeg
    \\   Hash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c
    \\   Dimensions: 2560 × 1920
    \\   File date: 2024-01-01T00:00:00.000Z
    \\   Photo date: 2025-05-27T09:54:16.000Z
    \\   Upload date: 2025-08-21T09:57:01.494Z
    \\   Coordinates: -29.019044444444443, 152.18946666666668
    \\   Labels: .., .., test
    \\
    \\📁 89171cd9-a652-4047-b869-1154bf2c95a1
    \\   Asset ID: 89171cd9-a652-4047-b869-1154bf2c95a1
    \\   Original file: test.jpg
    \\   Original path: ../../test
    \\   Type: image/jpeg
    \\   Hash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c
    \\   Dimensions: 2560 × 1920
    \\   File date: 2024-01-01T00:00:00.000Z
    \\   Photo date: 2025-05-27T09:54:16.000Z
    \\   Upload date: 2025-08-21T09:57:01.494Z
    \\   Coordinates: -29.019044444444443, 152.18946666666668
    \\   Labels: .., .., test
    \\
    \\📁 Asset ID: 00000000-0000-0000-0000-000000000000
    \\   Error: Asset not found in database
    \\
    \\
    \\Displayed info for 3 item(s).
    \\
    \\
;

//
// The report of infoCommand for test/test.png copied to <file>. The modified time of the copy is replaced by
// <modified>.
//
const info_png_report =
    \\
    \\Info for 1 item(s):
    \\
    \\📁 <file>
    \\   Type: image/png
    \\   Hash: 3d9d6f073e60a13e6706bec322b47615f76b594b17bd64495614996b995908d9
    \\   Size: 1.29 KiB
    \\   Modified: <modified>
    \\   Dimensions: 100 × 90
    \\
    \\
    \\Displayed info for 1 item(s).
    \\
    \\
;

//
// Replaces the text after "   Modified: " up to the end of its line with <modified>.
//
fn normalizeModified(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const marker = "   Modified: ";
    const start = (std.mem.indexOf(u8, text, marker) orelse return text) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.concat(allocator, u8, &.{ text[0..start], "<modified>", text[end..] });
}

test "info prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-info");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const lookups = [_][]const u8{ "426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c", "89171cd9-a652-4047-b869-1154bf2c95a1", "00000000-0000-0000-0000-000000000000" };
    try expectResult(try runZig(allocator, environment, &.{ "info", lookups[0], lookups[1], lookups[2], "--db", db, "--yes" }), info_v6_report, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "inf", lookups[0], lookups[1], lookups[2], "--db", db, "--yes" }), info_v6_report, "", 0);

    // A file path is hashed and analyzed; a path that does not exist shows nothing.
    const file = try std.fmt.allocPrint(allocator, "{s}/test.png", .{root});
    try std.Io.Dir.cwd().copyFile("../../test/test.png", std.Io.Dir.cwd(), file, std.testing.io, .{});
    const expected = try std.mem.replaceOwned(u8, allocator, info_png_report, "<file>", file);
    const result = try runZig(allocator, environment, &.{ "info", file, try std.fmt.allocPrint(allocator, "{s}/missing.jpg", .{root}), "--yes" });
    try expectResult(.{ .stdout = try normalizeModified(allocator, result.stdout), .stderr = result.stderr, .exitCode = result.exitCode }, expected, "", 0);
}

//
// The report of `psi verify --full` for test/dbs/v6 with its thumb file overwritten. The totals come from the
// files tree, so only the modified count changes; a verification that found problems prints the repair step and
// exits with 1, which retains the session's temporary files.
//
const verify_v6_modified_report =
    \\Asset files verified.
    \\
    \\Files imported:    1
    \\Total files:       4
    \\Total size:        2.74 MiB
    \\Files processed:   4
    \\Nodes processed:   7
    \\Unmodified:        3
    \\Modified:          1
    \\New:               0
    \\Removed:           0
    \\Failures:          0
    \\Record mismatches: 0
    \\
    \\Modified files:
    \\  ● thumb/89171cd9-a652-4047-b869-1154bf2c95a1
    \\
    \\Database files:
    \\  Total files:    8
    \\  Total size:     355 KiB
    \\  Valid files:    8
    \\  Invalid files:  0
    \\
    \\⚠️ Asset file verification found issues - see details above
    \\
    \\Next steps:
    \\    # Fix database issues by restoring from source
    \\    psi repair --source <backup-db-path>
    \\
    \\Temporary files retained for inspection: <session dir>
    \\
;

test "verify reports a modified file like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-verify-modified");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/thumb/89171cd9-a652-4047-b869-1154bf2c95a1", .{db}),
        .data = "changed",
    });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--yes", "--full" }), db, "<db>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try expectResult(result, verify_v6_modified_report, "", 1);
}

//
// What loadDatabase (apps/cli/src/lib/init-cmd.ts) prints, through outro, for a database path without a files
// tree, <missing> standing for the path, followed by the line of the termination handler that retains the session.
//
const verify_missing_report =
    \\
    \\✗ No database found at: <missing>
    \\  The database directory must contain a ".db" folder with files.dat or tree.dat.
    \\
    \\To create a new database at this directory, use:
    \\  psi init --db <missing>
    \\Temporary files retained for inspection: <session dir>
    \\
;

test "verify reports a missing database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-verify-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{root});
    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", missing, "--yes" }), missing, "<missing>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try expectResult(result, verify_missing_report, "", 1);
}

//
// The report of `psi replicate` (apps/cli/src/cmd/replicate.ts) from <db> to <dest>, with the two lines the
// replication task logs (packages/node-api/src/lib/replicate-database.worker.ts) through the worker log, for the
// counts of copied files and records.
//
fn replicateReport(allocator: std.mem.Allocator, copiedFiles: []const u8, copiedRecords: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\
        \\Replicating database:
        \\  Source:         <db>
        \\  Destination:    <dest>
        \\
        \\[W1:<task>] Replication started from <db> to <dest>
        \\[W1:<task>] Replication completed from <db> to <dest>
        \\📊 Replication Results
        \\
        \\Total files imported:      1
        \\Total files copied:        {s}
        \\
        \\Total records copied:      {s}
        \\
        \\✅ Replication completed successfully
        \\
        \\💡 Tip: You can run this command again anytime to update your replica when the source database changes.
        \\
        \\Next steps:
        \\    # Verify the integrity of the replicated database
        \\    psi verify --db <dest>
        \\
        \\    # Compare source and destination databases
        \\    psi compare --db <db> --dest <dest>
        \\
        \\    # Synchronize changes between two databases that have been independently changed
        \\    psi sync --db <db> --dest <dest>
        \\
        \\    # View summary of the replicated database
        \\    psi summary --db <dest>
        \\
    , .{ copiedFiles, copiedRecords });
}

test "replicate prints the report of the TypeScript CLI and copies the files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/replica", .{root});

    // The new replica already holds the README.md written when it is created, so the asset, display and thumb
    // files of the one asset are copied, with its one metadata record.
    const result = try normalize(allocator, try normalize(allocator, try runZig(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest, "--yes" }), dest, "<dest>"), db, "<db>");
    try expectResult(result, try replicateReport(allocator, "3", "1"), "", 0);

    const assetId = "89171cd9-a652-4047-b869-1154bf2c95a1";
    const sourceAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ db, assetId }), allocator, .unlimited);
    const replicaAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dest, assetId }), allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, sourceAsset, replicaAsset);

    // Replicating again to an existing destination with --yes updates it, and it has nothing to copy.
    const again = try normalize(allocator, try normalize(allocator, try runZig(allocator, environment, &.{ "rep", "--db", db, "--dest", dest, "--yes", "--partial" }), dest, "<dest>"), db, "<db>");
    try expectResult(again, try replicateReport(allocator, "0", "0"), "", 0);
}

test "replicate rejects --partial with --full like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate-flags");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const result = try runZig(allocator, environment, &.{ "replicate", "--db", db, "--dest", "/tmp/x", "--partial", "--full", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings("✗ --partial and --full cannot be used together. Please specify only one.\n", result.stderr);
}

test "replicate rejects a key for an unencrypted destination like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);

    // The destination is another (unencrypted) database.
    const result = try runZig(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest, "--dest-key", "k", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(
        \\✗ You specified an encryption key, but the destination database is not encrypted.
        \\  Either remove the --dest-key option, or replicate to a different location to create a new encrypted database.
        \\
    , result.stderr);
}

//
// Runs the Zig CLI with the arguments, its stdout written to a file.
//
fn runZigToFile(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, outputPath: []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigCliPath(allocator));
    try argv.appendSlice(allocator, args);
    return helpers.runCliToFile(allocator, argv.items, environment, outputPath);
}

//
// The name versionCommand (apps/cli/src/cmd/version.ts) gives each dependency line, in the order it prints them;
// ImageMagick is named for the kind of ImageMagick found.
//
const version_dependency_names = [_][]const []const u8{
    &.{ "ImageMagick", "ImageMagick (convert/identify)", "ImageMagick (magick)" },
    &.{"ffmpeg"},
    &.{"ffprobe"},
};

//
// Gets the cache directory getCacheDir (packages/node-utils/src/lib/fs.ts) returns in the CLI test environment,
// which sets neither PHOTOSPHERE_CACHE_DIR, XDG_CACHE_HOME nor LOCALAPPDATA.
//
fn expectedCacheDir(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.path.join(allocator, &.{ environment.get("USERPROFILE").?, "AppData", "Local", "photosphere", "cache" });
    }
    if (builtin.os.tag == .macos) {
        return std.fs.path.join(allocator, &.{ environment.get("HOME").?, "Library", "Caches", "photosphere" });
    }
    return std.fs.path.join(allocator, &.{ environment.get("HOME").?, ".cache", "photosphere" });
}

//
// Expects the report of versionCommand (apps/cli/src/cmd/version.ts). The versions of the tools on the machine
// are not known here, so each dependency line is checked for its name and the closing status for agreeing with
// which dependencies were found; the rest is exact.
//
fn expectVersionReport(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, root: []const u8, stdout: []const u8) !void {
    const header =
        \\
        \\📋 Version Information
        \\
        \\Photosphere: dev
        \\Database version: 6
        \\
        \\Dependencies:
        \\
    ;
    try std.testing.expect(std.mem.startsWith(u8, stdout, header));
    var lines = std.mem.splitScalar(u8, stdout[header.len..], '\n');
    var missingTools: std.ArrayList([]const u8) = .empty;
    var missingImageMagick = false;
    var missingFfmpeg = false;
    var missingFfprobe = false;
    for (version_dependency_names, 0..) |names, dependencyIndex| {
        const line = lines.next().?;
        var nameMatched = false;
        for (names) |name| {
            if (std.mem.startsWith(u8, line, try std.fmt.allocPrint(allocator, "  {s}: ", .{name}))) {
                nameMatched = true;
            }
        }
        try std.testing.expect(nameMatched);
        if (std.mem.endsWith(u8, line, ": Not found")) {
            switch (dependencyIndex) {
                0 => missingImageMagick = true,
                1 => missingFfmpeg = true,
                else => missingFfprobe = true,
            }
        }
    }

    // verifyTools (packages/tools/src/lib/tool-verification.ts) lists the missing tools in this order.
    if (missingImageMagick) {
        try missingTools.append(allocator, "ImageMagick");
    }
    if (missingFfprobe) {
        try missingTools.append(allocator, "ffprobe");
    }
    if (missingFfmpeg) {
        try missingTools.append(allocator, "ffmpeg");
    }
    const status = if (missingTools.items.len == 0)
        "✅ All dependencies are available\n"
    else
        try std.fmt.allocPrint(allocator, "⚠️  Some dependencies are missing: {s}\nRun \"psi tools\" for installation instructions\n", .{try std.mem.join(allocator, ", ", missingTools.items)});
    const tempDir = try std.fs.path.join(allocator, &.{ root, "tmp", "photosphere" });
    const expectedRest = try std.fmt.allocPrint(allocator, "\nDirectories:\n  Config: {s}/config\n  Temp: {s}\n  Log files: {s}\n  Cache: {s}\n\n{s}", .{
        root,
        tempDir,
        try std.fs.path.join(allocator, &.{ tempDir, "logs" }),
        try expectedCacheDir(allocator, environment),
        status,
    });
    try std.testing.expectEqualStrings(expectedRest, lines.rest());
}

test "version prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const result = try runZig(allocator, environment, &.{"version"});
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expectEqualStrings("", result.stderr);
    try expectVersionReport(allocator, environment, root, result.stdout);

    // The test environment has an empty news feed, so --quiet leaves the report as it is.
    const quiet = try runZig(allocator, environment, &.{ "-q", "version" });
    try std.testing.expectEqual(@as(u8, 0), quiet.exitCode);
    try std.testing.expectEqualStrings(result.stdout, quiet.stdout);
    try std.testing.expectEqualStrings("", quiet.stderr);
}

test "version written to a file is the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version-file");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const result = try runZigToFile(allocator, environment, &.{"version"}, try std.fmt.allocPrint(allocator, "{s}/zig.txt", .{root}));
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try expectVersionReport(allocator, environment, root, result.stdout);
}

test "--version prints the version like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version-option");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    // The version of packages/config/src/index.ts, printed by the --version option of apps/cli/index.ts.
    for ([_][]const []const u8{ &.{"--version"}, &.{ "ver", "--version" }, &.{ "version", "--version" } }) |args| {
        const result = try runZig(allocator, environment, args);
        try expectResult(result, "dev\n", "", 0);
    }
}

//
// Copies the CLI test environment, with deterministic IDs (NODE_ENV=testing) from a UUID counter of its own.
//
fn deterministicEnvironment(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, counterDir: []const u8) !*std.process.Environ.Map {
    const copy = try allocator.create(std.process.Environ.Map);
    copy.* = try environment.clone(allocator);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, counterDir);
    try copy.put("NODE_ENV", "testing");
    try copy.put("TEST_TMP_DIR", counterDir);
    return copy;
}

//
// Gets the tree.dat the TypeScript CLI writes for an empty sort index with the id: the one of the same index in
// test/dbs/no-assets (created by the TypeScript CLI) with its index id replaced and its trailing SHA-256 checksum
// of the bytes before it recomputed.
//
fn expectedEmptySortIndexTree(allocator: std.mem.Allocator, indexDirName: []const u8, indexId: []const u8) ![]const u8 {
    const fixturePath = try std.fmt.allocPrint(allocator, "../../test/dbs/no-assets/.db/bson/indexes/metadata/{s}/tree.dat", .{indexDirName});
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixturePath, allocator, .unlimited);

    // The index id is the first string of the header, after the version, the "IDXT" type code, a reserved word,
    // a count and the string length.
    const fixtureId = fixture[20..56];
    const body = try std.mem.replaceOwned(u8, allocator, fixture[0 .. fixture.len - 32], fixtureId, indexId);
    var checksum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &checksum, .{});
    return std.mem.concat(allocator, u8, &.{ body, &checksum });
}

//
// Expects a database to hold what createDatabase (packages/node-api/src/lib/media-file-database.ts) writes: the
// README.md of test/dbs/no-assets (DATABASE_README_CONTENT), a config.json of `{}`, a files tree with the
// database id and an empty sort index for hash ascending and photoDate descending with the index ids.
//
fn expectCreatedDatabase(allocator: std.mem.Allocator, dbDir: []const u8, databaseId: []const u8, hashIndexId: []const u8, photoDateIndexId: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const expectedReadme = try cwd.readFileAlloc(std.testing.io, "../../test/dbs/no-assets/README.md", allocator, .unlimited);
    try std.testing.expectEqualStrings(expectedReadme, try cwd.readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ dbDir, "README.md" }), allocator, .unlimited));
    try std.testing.expectEqualStrings("{}", try cwd.readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ dbDir, ".db/config.json" }), allocator, .unlimited));
    try std.testing.expectEqualSlices(u8, try expectedEmptySortIndexTree(allocator, "hash_asc", hashIndexId), try cwd.readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ dbDir, ".db/bson/indexes/metadata/hash_asc/tree.dat" }), allocator, .unlimited));
    try std.testing.expectEqualSlices(u8, try expectedEmptySortIndexTree(allocator, "photoDate_desc", photoDateIndexId), try cwd.readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ dbDir, ".db/bson/indexes/metadata/photoDate_desc/tree.dat" }), allocator, .unlimited));
    const storage = try storage_zig.storage_factory.createStorage(allocator, std.testing.io, dbDir, null, null);
    const tree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, std.testing.io, ".db/files.dat", storage.storage, "FTRE")).?;
    try std.testing.expectEqualStrings(databaseId, tree.id);
}

//
// The report of initCommand (apps/cli/src/cmd/init.ts) for a new unencrypted database at <db>.
//
const init_report =
    \\
    \\Creating a new media file database...
    \\
    \\✓  Created new media file database in <db>
    \\⚠️ Important: Never modify database files manually - always use the psi tool!
    \\
    \\
    \\Add media files:
    \\    cd <db>
    \\    psi add <file or directory>
    \\
    \\Or specify the path:
    \\    psi add --db <db> <file or directory>
    \\
    \\Examples:
    \\    psi add --db <db> photo.jpg   - Adds a single photo to the database
    \\    psi add --db <db> video.mp4   - Adds a single video to the database
    \\    psi add --db <db> directory/  - Adds all media files in a directory
    \\
    \\
;

test "init prints the report of the TypeScript CLI and creates the database it creates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const deterministic = try deterministicEnvironment(allocator, environment, try std.fmt.allocPrint(allocator, "{s}/ids", .{root}));

    // The UUIDs are those TestUuidGenerator (packages/node-utils/src/lib/test-uuid-generator.ts) gives for each
    // counter, as recorded from it in packages-zig/utils-zig/src/test/fixtures/test-uuid-generator.json. The
    // counter gives the session id (1), the database id (2) and the ids of the two sort indexes (3 and 4).
    const result = try normalize(allocator, try runZig(allocator, deterministic, &.{ "init", "--db", db, "--yes" }), db, "<db>");
    try expectResult(result, init_report, "", 0);
    try expectCreatedDatabase(allocator, db, "5c724a85-6b64-4e6a-9e15-dfa0821821e1", "aff78597-8c6d-46c1-82eb-9619293609fa", "3eccea68-7e30-4eb2-8b12-9396b07e9458");

    // A database with the identity of another database: the counter gives the session id (5) and the ids of the
    // two sort indexes (6 and 7).
    const related = try std.fmt.allocPrint(allocator, "{s}/related", .{root});
    const databaseId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    const relatedResult = try normalize(allocator, try runZig(allocator, deterministic, &.{ "i", "--db", related, "--database-id", databaseId, "-y" }), related, "<db>");
    try expectResult(relatedResult, init_report, "", 0);
    try expectCreatedDatabase(allocator, related, databaseId, "957e5fd7-2249-430b-b7ab-c9f3d6757d9e", "39ba1bde-83f4-40f9-b443-daa2d943982a");
}

//
// What createDatabase (apps/cli/src/lib/init-cmd.ts) prints, through outro, for a directory that is not empty,
// followed by the line of the termination handler that retains the session.
//
const init_not_empty_report =
    \\
    \\Creating a new media file database...
    \\
    \\✗ The directory <db> is not empty or already contains a database.
    \\  Please choose an empty directory or a non-existent one.
    \\Temporary files retained for inspection: <session dir>
    \\
;

test "init refuses a directory that is not empty like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-init-not-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "init", "--db", db, "--yes" }), db, "<db>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try expectResult(result, init_not_empty_report, "", 1);
}

test "init rejects a malformed --database-id like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init-database-id");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // normaliseDatabaseId (apps/cli/src/lib/init-cmd.ts) throws, and the error handler of apps/cli/index.ts logs
    // it and exits with 1.
    const result = try runZig(allocator, environment, &.{ "init", "--db", db, "--database-id", "not-a-uuid", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "\"not-a-uuid\" is not a database id. It should be a UUID, as printed by \"psi database-id --db <database>\".") != null);
}

//
// The report of initCommand (apps/cli/src/cmd/init.ts) for a new database at <db> encrypted with a generated key
// named zig-key.
//
const init_encrypted_report =
    \\
    \\Creating a new media file database...
    \\
    \\✓  Created new media file database in <db>
    \\⚠️ Important: Never modify database files manually - always use the psi tool!
    \\
    \\✓  Encryption key "zig-key" stored.
    \\⚠️ Keep this key safe! You will need it to access your encrypted database.
    \\
    \\
    \\Add media files:
    \\    cd <db>
    \\    psi add <file or directory>
    \\
    \\Or specify the path:
    \\    psi add --db <db> <file or directory>
    \\
    \\When using your encrypted database, specify the key name:
    \\    psi add --key zig-key <file or directory>
    \\
    \\Examples:
    \\    psi add --db <db> --key zig-key photo.jpg   - Adds a single photo to the database
    \\    psi add --db <db> --key zig-key video.mp4   - Adds a single video to the database
    \\    psi add --db <db> --key zig-key directory/  - Adds all media files in a directory
    \\
    \\
;

test "init creates an encrypted database with a generated key like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init-encrypted");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "init", "--db", db, "--key", "zig-key", "--generate-key", "--yes" }), db, "<db>");
    try expectResult(result, init_encrypted_report, "", 0);

    // The public key marks the database as encrypted, and the database opens with the key.
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, try std.fs.path.join(allocator, &.{ db, ".db/encryption.pub" }), .{});
    const verifyResult = try runZig(allocator, environment, &.{ "verify", "--db", db, "--key", "zig-key", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), verifyResult.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, verifyResult.stdout, "✅ Database verification passed - all files are intact") != null);
}
