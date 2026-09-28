const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("test-helpers.zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_path = @import("node-utils-zig").path;

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
// The report of compareCommand (apps/cli/src/cmd/compare.ts) for test/dbs/1-asset against test/dbs/1-asset-2 with
// --max 1. <root> stands for the test root.
//
const compare_report =
    \\
    \\Comparing two databases:
    \\  Source:         <root>/1-asset
    \\  Destination:    <root>/1-asset-2
    \\
    \\
    \\📊 Comparison Results
    \\
    \\Found differences: 3 files only in source, 3 files only in destination
    \\
    \\Files only in source:
    \\  + asset/63e9c63a-9164-6376-13e9-ef4d00000000
    \\  ... and 2 more
    \\
    \\Files only in destination:
    \\  + asset/476dffbb-af9e-4cda-8006-b02f3851e86c
    \\  ... and 2 more
    \\
    \\⚠️ Databases have 6 differences
    \\
;

test "compare prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-compare");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const source = try std.fmt.allocPrint(allocator, "{s}/1-asset", .{root});
    const destination = try std.fmt.allocPrint(allocator, "{s}/1-asset-2", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset", source);
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset-2", destination);

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "compare", "--db", source, "--dest", destination, "--max", "1", "--yes" }), root, "<root>");
    try expectResult(result, compare_report, "", 0);

    // A database compared with itself (the destination comes from the origin of the source).
    try expectResult(try runZig(allocator, environment, &.{ "set-origin", "--db", source, source, "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Origin set to: {s}\n", .{source}), "", 0);
    const same = try normalize(allocator, try runZig(allocator, environment, &.{ "cmp", "--db", source, "--yes" }), root, "<root>");
    try expectResult(same, "\nComparing two databases:\n  Source:         <root>/1-asset\n  Destination:    <root>/1-asset\n\n\n\u{1F4CA} Comparison Results\n\nNo differences detected\n", "", 0);
}

test "remove deletes the asset like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-remove");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const assetId = "89171cd9-a652-4047-b869-1154bf2c95a1";

    try expectResult(try runZig(allocator, environment, &.{ "rm", "--db", db, assetId, "--yes" }), "\u{2713} Successfully removed asset 89171cd9-a652-4047-b869-1154bf2c95a1 from database\n", "", 0);

    // The files are gone, and the tree holds only README.md with the hash the TypeScript CLI leaves.
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "asset", "display", "thumb" }) |directory| {
        try std.testing.expectError(error.FileNotFound, cwd.statFile(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ db, directory, assetId }), .{}));
    }
    const summary = try runZig(allocator, environment, &.{ "summary", "--db", db, "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, summary.stdout, "Files imported:   0\nTotal files:      1\nTotal size:       913 Bytes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.stdout, "Files hash:       94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7\n") != null);

    // The record is gone and its ID is recorded as deleted.
    const info = try runZig(allocator, environment, &.{ "info", assetId, "--db", db, "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, info.stdout, "Error: Asset not found in database") != null);
    const storage = try storage_zig.storage_factory.createStorage(allocator, std.testing.io, db, null, null);
    const filesTree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, std.testing.io, ".db/files.dat", storage.storage, "FTRE")).?;
    const deletedAssetIds = filesTree.databaseMetadata.?.get("deletedAssetIds").?.array;
    try std.testing.expectEqual(@as(usize, 1), deletedAssetIds.len);
    try std.testing.expectEqualStrings(assetId, deletedAssetIds[0].string);
}

test "export writes the asset files and prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-export");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const assetId = "89171cd9-a652-4047-b869-1154bf2c95a1";
    const cwd = std.Io.Dir.cwd();

    // The original to a file path (its directory is created).
    const original = try std.fmt.allocPrint(allocator, "{s}/out/original.jpg", .{root});
    try expectResult(try runZig(allocator, environment, &.{ "export", "--db", db, assetId, original, "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Successfully exported original version of asset {s} to {s}\n", .{ assetId, original }), "", 0);
    try std.testing.expectEqualSlices(u8, try cwd.readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ db, assetId }), allocator, .unlimited), try cwd.readFileAlloc(std.testing.io, original, allocator, .unlimited));

    // The display and thumb versions to a directory, named after the original file with the type.
    const outDir = try std.fmt.allocPrint(allocator, "{s}/out", .{root});
    const display = try node_path.join(allocator, &.{ outDir, "test_display.jpg" });
    try expectResult(try runZig(allocator, environment, &.{ "exp", "--db", db, assetId, outDir, "--type", "display", "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Successfully exported display version of asset {s} to {s}\n", .{ assetId, display }), "", 0);
    try std.testing.expectEqualSlices(u8, try cwd.readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/display/{s}", .{ db, assetId }), allocator, .unlimited), try cwd.readFileAlloc(std.testing.io, display, allocator, .unlimited));
    const thumb = try node_path.join(allocator, &.{ outDir, "test_thumb.jpg" });
    try expectResult(try runZig(allocator, environment, &.{ "export", "--db", db, assetId, outDir, "-t", "thumb", "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Successfully exported thumb version of asset {s} to {s}\n", .{ assetId, thumb }), "", 0);
    try std.testing.expectEqualSlices(u8, try cwd.readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/thumb/{s}", .{ db, assetId }), allocator, .unlimited), try cwd.readFileAlloc(std.testing.io, thumb, allocator, .unlimited));

    // An asset that is not in the database.
    const missing = try runZig(allocator, environment, &.{ "export", "--db", db, "00000000-0000-0000-0000-000000000000", original, "--yes" });
    try std.testing.expectEqual(@as(u8, 1), missing.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, missing.stderr, "Asset 00000000-0000-0000-0000-000000000000 not found in database.\n"));
}

test "root-hash and database-id print the values of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-root-hash");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // The values the TypeScript CLI prints for test/dbs/v6.
    try expectResult(try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" }), "c18854777b06e1b0d499230db43f74b32bf937cd892c974b673621b979f40590\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "database-id", "--db", db, "--yes" }), "85fe592c-9b92-4fa1-9ec5-f87f01cf8e72\n", "", 0);
}

test "origin and set-origin read and write the origin like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-origin");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    try expectResult(try runZig(allocator, environment, &.{ "origin", "--db", db, "--yes" }), "(not set)\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "set-origin", "--db", db, "s3:bucket/x", "--yes" }), "\u{2713} Origin set to: s3:bucket/x\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "origin", "--db", db, "--yes" }), "s3:bucket/x\n", "", 0);

    // The config file the TypeScript CLI writes.
    const config = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/.db/config.json", .{db}), allocator, .unlimited);
    try std.testing.expectEqualStrings("{\n  \"origin\": \"s3:bucket/x\"\n}", config);
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
    const file = try node_path.join(allocator, &.{ root, "test.png" });
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
// The report of `psi repair` (apps/cli/src/cmd/repair.ts) restoring the modified thumbnail of <db> from <src>.
//
const repair_modified_report =
    \\
    \\Repairing database:
    \\  Source:    <src>
    \\  Target:    <db>
    \\
    \\
    \\🔧 Repair completed - processed 4 files.
    \\
    \\Files imported:   1
    \\Total files:      4
    \\Total size:       2.74 MiB
    \\Nodes processed:  7
    \\Unmodified:       3
    \\Modified:         0
    \\New:              0
    \\Removed:          0
    \\Repaired:         1
    \\Unrepaired:       0
    \\Records repaired: 0
    \\
    \\Repaired files:
    \\  ✓ thumb/89171cd9-a652-4047-b869-1154bf2c95a1
    \\
    \\✅ Database repair completed successfully
    \\
    \\Next steps:
    \\    # Verify the repaired database integrity
    \\    psi verify --db <db>
    \\
    \\    # View database summary and tree hash
    \\    psi summary --db <db>
    \\
;

test "repair restores a modified file and prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-repair");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const src = try std.fmt.allocPrint(allocator, "{s}/src", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", src);
    const thumb = try std.fmt.allocPrint(allocator, "{s}/thumb/89171cd9-a652-4047-b869-1154bf2c95a1", .{db});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = thumb,
        .data = "changed",
    });

    const result = try normalize(allocator, try normalize(allocator, try runZig(allocator, environment, &.{ "repair", "--db", db, "--source", src, "--yes" }), src, "<src>"), db, "<db>");
    try expectResult(result, repair_modified_report, "", 0);

    const original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/thumb/89171cd9-a652-4047-b869-1154bf2c95a1", .{src}), allocator, .unlimited);
    const repaired = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, thumb, allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, original, repaired);
}

test "repair without a source or an origin fails like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-repair-no-source");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    var result = try runZig(allocator, environment, &.{ "repair", "--db", db, "--yes" });
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "Source database path is required for repair command. Specify --source or set an origin (psi set-origin <path>).\n"));
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "\nErrors, warnings, and exceptions were logged to: "));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
}

//
// The report of `psi find-orphans` (apps/cli/src/cmd/find-orphans.ts) for <db> with two stray files.
//
const find_orphans_report =
    \\
    \\Finding orphaned files in database:
    \\  Database: <db>
    \\
    \\
    \\📋 Orphaned Files
    \\
    \\  ✗ asset/orphan-1
    \\  ✗ other/file
    \\
    \\⚠️  Found 2 orphaned file(s) that exist in storage but are not tracked in the merkle tree.
    \\     Use 'psi remove-orphans' to remove them.
    \\
;

//
// The report of `psi find-orphans` (apps/cli/src/cmd/find-orphans.ts) for <db> without stray files.
//
const find_orphans_none_report =
    \\
    \\Finding orphaned files in database:
    \\  Database: <db>
    \\
    \\
    \\📋 Orphaned Files
    \\
    \\✓ No orphaned files found
    \\
;

test "find-orphans prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-find-orphans");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const clean = try normalize(allocator, try runZig(allocator, environment, &.{ "find-orphans", "--db", db, "--yes" }), db, "<db>");
    try expectResult(clean, find_orphans_none_report, "", 0);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/other", .{db}));
    try cwd.writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/asset/orphan-1", .{db}),
        .data = "x",
    });
    try cwd.writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/other/file", .{db}),
        .data = "x",
    });
    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "find-orphans", "--db", db, "--yes" }), db, "<db>");
    try expectResult(result, find_orphans_report, "", 0);
}

//
// The report of `psi remove-orphans --yes` (apps/cli/src/cmd/remove-orphans.ts) for <db> with two stray files.
//
const remove_orphans_report =
    \\
    \\Finding orphaned files in database:
    \\  Database: <db>
    \\
    \\
    \\🗑️  Remove Orphaned Files
    \\
    \\  ✗ asset/orphan-1
    \\  ✗ other/file
    \\
    \\
    \\✓ Successfully deleted 2 orphaned file(s)
    \\
;

//
// The report of `psi remove-orphans` (apps/cli/src/cmd/remove-orphans.ts) for <db> without stray files.
//
const remove_orphans_none_report =
    \\
    \\Finding orphaned files in database:
    \\  Database: <db>
    \\
    \\
    \\🗑️  Remove Orphaned Files
    \\
    \\✓ No orphaned files found
    \\
;

test "remove-orphans deletes the orphans and prints the report of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-remove-orphans");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const cwd = std.Io.Dir.cwd();
    const orphan = try std.fmt.allocPrint(allocator, "{s}/asset/orphan-1", .{db});
    const other = try std.fmt.allocPrint(allocator, "{s}/other/file", .{db});
    try cwd.createDirPath(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/other", .{db}));
    try cwd.writeFile(std.testing.io, .{
        .sub_path = orphan,
        .data = "x",
    });
    try cwd.writeFile(std.testing.io, .{
        .sub_path = other,
        .data = "x",
    });

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "remove-orphans", "--db", db, "--yes" }), db, "<db>");
    try expectResult(result, remove_orphans_report, "", 0);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, orphan, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, other, .{}));
    try cwd.access(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/89171cd9-a652-4047-b869-1154bf2c95a1", .{db}), .{});

    const again = try normalize(allocator, try runZig(allocator, environment, &.{ "remove-orphans", "--db", db, "--yes" }), db, "<db>");
    try expectResult(again, remove_orphans_none_report, "", 0);
}

//
// The report of `psi upgrade --yes` (apps/cli/src/cmd/upgrade.ts) upgrading the v5 test database at <db>, with the
// line the logger adds for the warnings.
//
const upgrade_v5_report =
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
    \\    psi summary --db <db>
    \\
    \\    # Verify the integrity of the upgraded database
    \\    psi verify --db <db>
    \\
    \\
;

//
// What `psi upgrade` (apps/cli/src/cmd/upgrade.ts) writes to stderr upgrading <db>. The backup command it suggests
// is `xcopy` on Windows and `cp -r` everywhere else.
//
const upgrade_warnings = if (builtin.os.tag == .windows) upgrade_warnings_windows else upgrade_warnings_posix;

//
// The upgrade warnings on Windows, suggesting `xcopy` for the backup.
//
const upgrade_warnings_windows =
    \\⚠️  IMPORTANT: Database upgrade will modify your database files.
    \\    It is strongly recommended to backup your database before proceeding.
    \\    You can backup your database by copying the entire directory:
    \\    xcopy "<db>" "<db>-backup" /E /I
    \\
;

//
// The upgrade warnings on Linux and macOS, suggesting `cp -r` for the backup.
//
const upgrade_warnings_posix =
    \\⚠️  IMPORTANT: Database upgrade will modify your database files.
    \\    It is strongly recommended to backup your database before proceeding.
    \\    You can backup your database by copying the entire directory:
    \\    cp -r "<db>" "<db>-backup"
    \\
;

//
// Removes the line naming the error log (its name has the time in it).
//
fn withoutErrorLogLine(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const marker = "Errors, warnings, and exceptions were logged to: ";
    const start = std.mem.indexOf(u8, text, marker) orelse return text;
    const end = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len - 1) + 1;
    return std.mem.concat(allocator, u8, &.{ text[0..start], text[end..] });
}

test "upgrade upgrades the v5 database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-upgrade");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v5", db);

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "upgrade", "--db", db, "--yes" }), db, "<db>");
    result.stdout = try withoutErrorLogLine(allocator, result.stdout);
    try expectResult(result, upgrade_v5_report, upgrade_warnings, 0);

    // The root hash TypeScript's upgrade of the same database gives.
    const rootHash = try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" });
    try std.testing.expectEqualStrings("c18854777b06e1b0d499230db43f74b32bf937cd892c974b673621b979f40590\n", rootHash.stdout);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/metadata", .{db}), .{}));

    const again = try normalize(allocator, try runZig(allocator, environment, &.{ "upgrade", "--db", db, "--yes" }), db, "<db>");
    try expectResult(again, "\nUpgrading media file database...\n✓ Found database version 6\n✓ Database is already at the latest version (6)\n", "", 0);
}

//
// Replaces the milliseconds of every "Sync timings" line (`"...Ms":<number>`) with N, because they are times.
//
fn maskSyncTimings(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "Ms\":")) {
            try result.appendSlice(allocator, "Ms\":N");
            index += "Ms\":".len;
            while (index < text.len and (std.ascii.isDigit(text[index]) or text[index] == '-')) {
                index += 1;
            }
            continue;
        }
        try result.append(allocator, text[index]);
        index += 1;
    }
    return result.items;
}

//
// The report of `psi sync` (apps/cli/src/cmd/sync.ts and packages/node-api/src/lib/sync.ts) from <root>/db to
// <root>/dest, a copy of the same database with its one asset removed: the pull deletes the asset from <root>/db.
//
const sync_report =
    \\Starting database sync operation...
    \\  Source:    <root>/db
    \\  Target:    <root>/dest
    \\
    \\Sync timings: {"filesCopied":0,"leavesVisited":0,"nodesVisited":0,"bytesCopied":0,"elapsedMs":N,"copyFileMs":N,"diffMs":N,"decideMs":N,"openSourceMs":N,"sourceInfoMs":N,"writeMs":N,"treeUpdateMs":N,"treeSaveMs":N,"loggingMs":N,"unaccountedMs":N}
    \\Push completed: 0 files copied, 0 left behind for the next pass, 1 deleted from target
    \\Finding differing records using hierarchical merkle trees...
    \\No differing records found.
    \\Finding differing records using hierarchical merkle trees...
    \\No differing records found.
    \\Sync completed successfully!
    \\
;

test "sync synchronizes two databases like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    const assetId = "89171cd9-a652-4047-b869-1154bf2c95a1";
    try expectResult(try runZig(allocator, environment, &.{ "remove", "--db", dest, assetId, "--yes" }), "\u{2713} Successfully removed asset 89171cd9-a652-4047-b869-1154bf2c95a1 from database\n", "", 0);

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--yes" }), root, "<root>");
    result.stdout = try maskSyncTimings(allocator, result.stdout);
    try expectResult(result, sync_report, "", 0);

    // The asset the destination removed is gone from the source too, and the two hold the same files.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ db, assetId }), .{}));
    const sourceHash = try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" });
    const destHash = try runZig(allocator, environment, &.{ "root-hash", "--db", dest, "--yes" });
    try std.testing.expectEqualStrings("94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7\n", sourceHash.stdout);
    try std.testing.expectEqualStrings(sourceHash.stdout, destHash.stdout);
}

test "sync does nothing for databases already in sync like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync-in-sync");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);

    // Two copies of one database hold the same files and records, but have no state files yet, so the first
    // sync runs and records their content hashes.
    const first = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--yes" }), root, "<root>");
    try expectResult(first, "Starting database sync operation...\n  Source:    <root>/db\n  Target:    <root>/dest\n\nSync completed successfully!\n", "", 0);

    const second = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--yes" }), root, "<root>");
    try expectResult(second, "Starting database sync operation...\n  Source:    <root>/db\n  Target:    <root>/dest\n\nDatabases already in sync, nothing to do.\n", "", 0);
}

test "sync refuses an encrypted destination without a key like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync-encrypted");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);

    // The encryption marker is what says a database is encrypted.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{dest}), .data = "a public key\n" });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--yes" }), root, "<root>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(
        \\✗ The destination database is encrypted and requires a private key to access.
        \\  Please provide the private key using the --dest-key option.
        \\
        \\Example:
        \\    psi sync --dest-key my-photos.key --dest <root>/dest
        \\    psi sync --dest-key <full or relative path to key> --dest <root>/dest
        \\
    , result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Starting database sync operation...\n  Source:    <root>/db\n  Target:    <root>/dest\n\n\nErrors, warnings, and exceptions were logged to: "));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
}

test "sync rejects a key for an unencrypted destination like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);

    const result = try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--dest-key", "k", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(
        \\✗ You specified an encryption key, but the destination database is not encrypted.
        \\  Either remove the --dest-key option, or sync to a different location.
        \\
    , result.stderr);
}

test "sync refuses databases that are not related like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync-unrelated");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const other = try std.fmt.allocPrint(allocator, "{s}/other", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset", other);

    // The TypeScript CLI also prints the stack of each error of the chain, which Zig errors do not have.
    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", other, "--yes" }), root, "<root>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(
        \\An unknown error occurred
        \\Error: Sync gave up while pulling files from the origin: You are trying to sync databases that have different IDs.
        \\Source database ID: 93886ac9-16e4-48e6-983b-ec65566018d0
        \\Target database ID: 85fe592c-9b92-4fa1-9ec5-f87f01cf8e72
        \\The databases are not related to each other.
        \\Caused by:
        \\FatalError: You are trying to sync databases that have different IDs.
        \\Source database ID: 93886ac9-16e4-48e6-983b-ec65566018d0
        \\Target database ID: 85fe592c-9b92-4fa1-9ec5-f87f01cf8e72
        \\The databases are not related to each other.
        \\
    , result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Starting database sync operation...\n  Source:    <root>/db\n  Target:    <root>/other\n\n\nIf you believe this behaviour is a bug, please report it with the following command:\n   psi bug\n\nErrors, warnings, and exceptions were logged to: "));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
}

test "sync --watch rejects an interval that is not a number like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-sync-interval");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);

    // The TypeScript CLI also prints the stack of the error, which Zig errors do not have.
    const result = try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--watch", "--interval", "hourly", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings("An unknown error occurred\nError: --interval must be a positive number of seconds, got \"hourly\".\n", result.stderr);
}

//
// Replaces who holds a write lock and since when in the "Failed to acquire write lock" warning
// (`held by "<owner>" since <time> ago (acquired at <date>)`), because the owner is a session id and the rest are
// times.
//
fn maskLockHolder(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const label = "Lock is currently held by ";
    const start = std.mem.indexOf(u8, text, label) orelse {
        return text;
    };
    const end = std.mem.indexOfPos(u8, text, start, ").") orelse text.len;
    return std.mem.concat(allocator, u8, &.{ text[0 .. start + label.len], "<holder>", text[end..] });
}

//
// The first lines of `psi consolidate` (apps/cli/src/cmd/consolidate.ts) from <root>/db to <root>/<remote>.
//
fn consolidateHeader(allocator: std.mem.Allocator, remote: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\Connecting to a remote database.
        \\  Database:  <root>/db
        \\  Remote:    <root>/{s}
        \\
        \\
    , .{remote});
}

test "consolidate creates a remote that does not exist, then finds it already joined, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-consolidate-create");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const remote = try std.fmt.allocPrint(allocator, "{s}/remote", .{root});

    const created = try normalize(allocator, try runZig(allocator, environment, &.{ "consolidate", "--db", db, remote, "--yes" }), root, "<root>");
    try expectResult(created, try std.mem.concat(allocator, u8, &.{ try consolidateHeader(allocator, "remote"),
        \\There is no database at the remote path, so it is being created as a copy of this one.
        \\[W1:<task>] Replication started from <root>/db to <root>/remote
        \\[W1:<task>] Replication completed from <root>/db to <root>/remote
        \\✓ Created the remote database and set it as this database's origin.
        \\
    }), "", 0);

    // The remote is a copy of the database, and is now its origin.
    const sourceHash = try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" });
    const remoteHash = try runZig(allocator, environment, &.{ "root-hash", "--db", remote, "--yes" });
    try std.testing.expectEqualStrings(sourceHash.stdout, remoteHash.stdout);
    const origin = try normalize(allocator, try runZig(allocator, environment, &.{ "origin", "--db", db, "--yes" }), root, "<root>");
    try std.testing.expectEqualStrings("<root>/remote\n", origin.stdout);

    const again = try normalize(allocator, try runZig(allocator, environment, &.{ "consolidate", "--db", db, remote, "--yes" }), root, "<root>");
    try expectResult(again, try std.mem.concat(allocator, u8, &.{ try consolidateHeader(allocator, "remote"), "\u{2713} Already joined to <root>/remote.\n" }), "", 0);
}

test "consolidate records a remote that is the same database as the origin like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-consolidate-same");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const same = try std.fmt.allocPrint(allocator, "{s}/same", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", same);

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "consolidate", "--db", db, same, "--yes" }), root, "<root>");
    try expectResult(result, try std.mem.concat(allocator, u8, &.{ try consolidateHeader(allocator, "same"), "\u{2713} The remote is the same database, so it has been set as this database's origin.\n" }), "", 0);

    const origin = try normalize(allocator, try runZig(allocator, environment, &.{ "origin", "--db", db, "--yes" }), root, "<root>");
    try std.testing.expectEqualStrings("<root>/same\n", origin.stdout);
}

test "consolidate joins an unrelated remote like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-consolidate-unrelated");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const other = try std.fmt.allocPrint(allocator, "{s}/other", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset-2", other);

    // The warning is the local write lock that replicating the remote down cannot take while consolidation holds it,
    // as in TypeScript.
    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "consolidate", "--db", db, other, "--yes" }), root, "<root>");
    result.stderr = try maskLockHolder(allocator, result.stderr);
    try expectResult(result, try std.mem.concat(allocator, u8, &.{ try consolidateHeader(allocator, "other"),
        \\The remote holds a different database, so the two are being consolidated.
        \\Content the remote already has is not pushed a second time.
        \\
        \\[W1:<task>] Consolidating "<root>/db" into "<root>/other".
        \\[W1:<task>] Consolidated "<root>/db" into "<root>/other": 1 pushed, 0 already there.
        \\✓ Connected to <root>/other.
        \\Assets pushed to the remote:      1
        \\Assets the remote already had:    0
        \\
        \\Next steps:
        \\    # Bring down everything the remote has that this database does not
        \\    psi sync --db <root>/db
        \\
    }), "[W1:<task>] Failed to acquire write lock after 3 attempts. Lock is currently held by <holder>).\n", 0);

    // The remote holds its own photo and the one pushed, and the database is now a partial replica of it.
    var assetDir = try std.Io.Dir.cwd().openDir(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset", .{other}), .{ .iterate = true });
    defer assetDir.close(std.testing.io);
    var assetCount: usize = 0;
    var assets = assetDir.iterate();
    while (try assets.next(std.testing.io)) |entry| {
        _ = entry;
        assetCount += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), assetCount);
    const dbHash = try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" });
    const otherHash = try runZig(allocator, environment, &.{ "root-hash", "--db", other, "--yes" });
    try std.testing.expectEqualStrings(otherHash.stdout, dbHash.stdout);
    const summary = try runZig(allocator, environment, &.{ "summary", "--db", db, "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, summary.stdout, "Mode:             partial\n") != null);
}

test "consolidate reports a remote it cannot lock like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-consolidate-locked");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const locked = try std.fmt.allocPrint(allocator, "{s}/locked", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset-2", locked);

    // Another session holds the remote's write lock, with a timestamp that never times out.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/write.lock", .{locked}),
        .data = "{\"owner\":\"other-session\",\"acquiredAt\":\"2026-01-01T00:00:00.000Z\",\"timestamp\":9999999999999}",
    });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "consolidate", "--db", db, locked, "--yes" }), root, "<root>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    result.stderr = try maskLockHolder(allocator, result.stderr);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(
        \\[W1:<task>] Failed to acquire write lock after 3 attempts. Lock is currently held by <holder>).
        \\✗ Consolidation failed: Failed to acquire the write lock on the remote database at <root>/locked.
        \\
    , result.stderr);
    const expectedStart = try std.mem.concat(allocator, u8, &.{ try consolidateHeader(allocator, "locked"),
        \\The remote holds a different database, so the two are being consolidated.
        \\Content the remote already has is not pushed a second time.
        \\
        \\[W1:<task>] Consolidating "<root>/db" into "<root>/locked".
        \\
        \\Errors, warnings, and exceptions were logged to: 
    });
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, expectedStart));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
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

//
// The report of `psi verify` for test/dbs/v6 once `psi encrypt` has encrypted it: the asset, display and thumb
// files each grow by the encryption header and wrapped key, so the files tree totals 2.75 MiB where the plain
// database's totals 2.74 MiB (README.md is not encrypted).
//
const verify_v6_encrypted_report =
    \\Asset files verified.
    \\
    \\Files imported:    1
    \\Total files:       4
    \\Total size:        2.75 MiB
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
// Expects a command that failed before doing anything to have written the error to stderr and exited with 1, the
// termination callbacks of initContext (apps/cli/src/lib/init-cmd.ts) having written where the log and the
// temporary files were left to stdout.
//
fn expectEncryptFailure(allocator: std.mem.Allocator, result: helpers.CliResult, expectedStderr: []const u8) !void {
    const stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try std.testing.expectEqualStrings(expectedStderr, result.stderr);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, stdout, "Temporary files retained for inspection: <session dir>\n\nErrors, warnings, and exceptions were logged to: "));
    try std.testing.expect(std.mem.endsWith(u8, stdout, "-errors.log\n"));
}

test "encrypt encrypts the database in place, then skips what it already encrypted, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-encrypt");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // test/dbs/v6 holds 11 files that encryptableFiles (packages/node-api/src/lib/encrypt.ts) yields: the asset,
    // display and thumb files, and 8 files under .db/bson.
    const first = try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--key", "zig-key", "--generate-key", "--yes" });
    try expectResult(first, "\n✅ Encrypted 11 files, 0 were already encrypted.\n", "", 0);

    const second = try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--key", "zig-key", "--yes" });
    try expectResult(second, "\n✅ Encrypted 0 files, 11 were already encrypted.\n", "", 0);

    // The public key marks the database as encrypted, the asset is no longer stored in plain form, and the
    // database verifies with the key.
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, try std.fs.path.join(allocator, &.{ db, ".db/encryption.pub" }), .{});
    const assetPath = try std.fs.path.join(allocator, &.{ db, "asset/89171cd9-a652-4047-b869-1154bf2c95a1" });
    const storedAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, assetPath, allocator, .unlimited);
    try std.testing.expectEqualStrings("PSEN", storedAsset[0..4]);
    const verifyResult = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--key", "zig-key", "--yes" }), db, "<db>");
    try expectResult(verifyResult, verify_v6_encrypted_report, "", 0);
}

test "encrypt without a key fails like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-encrypt-no-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const withoutKey = try normalize(allocator, try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, withoutKey, "✗ Encryption requires --key.\n");

    // A key that is not in the vault cannot be added without prompting, so it is the same as no key.
    const missingKey = try normalize(allocator, try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--key", "missing", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, missingKey, "✗ Encryption requires --key.\n");
}

test "encrypt reports a missing database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-encrypt-no-db");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const missingDb = try std.fmt.allocPrint(allocator, "{s}/nodb", .{root});

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "encrypt", "--db", missingDb, "--key", "zig-key", "--generate-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, result, "✗ No database found at: <root>/nodb\n");
}

test "encrypt requires a database directory like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-encrypt-empty-db");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "encrypt", "--db", "", "--key", "zig-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, result, "✗ Database directory is required (--db).\n");
}

test "decrypt decrypts the database in place like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-decrypt");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const encrypted = try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--key", "zig-key", "--generate-key", "--yes" });
    try expectResult(encrypted, "\n✅ Encrypted 11 files, 0 were already encrypted.\n", "", 0);

    // The 11 files that decryptableFiles (packages/node-api/src/lib/decrypt.ts) yields are all rewritten, because
    // the plain storage written to is not the encrypted storage read from.
    const decrypted = try runZig(allocator, environment, &.{ "decrypt", "--db", db, "--key", "zig-key", "--yes" });
    try expectResult(decrypted, "\n✅ Decrypted 11 files, 0 were already plain.\n", "", 0);

    // The public key is gone, the asset is stored as it was before it was encrypted, and the database verifies
    // and hashes as the plain test/dbs/v6 does, without a key.
    const publicKeyPath = try std.fs.path.join(allocator, &.{ db, ".db", "encryption.pub" });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, publicKeyPath, .{}));
    const assetName = "asset/89171cd9-a652-4047-b869-1154bf2c95a1";
    const storedAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ db, assetName }), allocator, .unlimited);
    const originalAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ "../../test/dbs/v6", assetName }), allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, originalAsset, storedAsset);
    const verifyResult = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--yes" }), db, "<db>");
    try expectResult(verifyResult, verify_v6_report, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "root-hash", "--db", db, "--yes" }), "c18854777b06e1b0d499230db43f74b32bf937cd892c974b673621b979f40590\n", "", 0);

    // Once decrypted, the database is no longer encrypted, so decrypting it again fails.
    const again = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", db, "--key", "zig-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, again, "✗ Database at <root>/db does not appear to be encrypted (no .db/encryption.pub).\n");
}

test "decrypt without a key fails like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-decrypt-no-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const withoutKey = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", db, "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, withoutKey, "✗ Decryption requires --key.\n");

    // A key that is not in the vault resolves to no key at all.
    const missingKey = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", db, "--key", "missing", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, missingKey, "✗ Decryption requires --key.\n");
}

test "decrypt reports a database that is not encrypted like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-decrypt-plain");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const missingDb = try std.fmt.allocPrint(allocator, "{s}/nodb", .{root});

    // The key must be in the vault for the database to be checked, so it is generated by encrypting another copy.
    const other = try std.fmt.allocPrint(allocator, "{s}/other", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", other);
    const encryptOther = try runZig(allocator, environment, &.{ "encrypt", "--db", other, "--key", "zig-key", "--generate-key", "--yes" });
    try expectResult(encryptOther, "\n✅ Encrypted 11 files, 0 were already encrypted.\n", "", 0);

    const plain = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", db, "--key", "zig-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, plain, "✗ Database at <root>/db does not appear to be encrypted (no .db/encryption.pub).\n");

    const missing = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", missingDb, "--key", "zig-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, missing, "✗ Database at <root>/nodb does not appear to be encrypted (no .db/encryption.pub).\n");
}

test "decrypt requires a database directory like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-decrypt-empty-db");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "decrypt", "--db", "", "--key", "zig-key", "--yes" }), root, "<root>");
    try expectEncryptFailure(allocator, result, "✗ Database directory is required (--db).\n");
}

//
// The modified time the hash tests give their files: 2024-01-02T03:04:05.678Z, which hashCommand
// (apps/cli/src/cmd/hash.ts) prints to the second as "2024-01-02 03:04:05".
//
const hash_test_modified_milliseconds: i64 = 1704164645678;

//
// Sets the modified time of a file to hash_test_modified_milliseconds.
// Set through the open file: Zig 0.16 panics in Dir.setTimestamps on Windows, while File.setTimestamps is implemented.
//
fn setHashTestModifiedTime(filePath: []const u8) !void {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, filePath, .{ .mode = .write_only });
    defer file.close(io);
    const modified: std.Io.Timestamp = .{ .nanoseconds = @as(i96, hash_test_modified_milliseconds) * std.time.ns_per_ms };
    try file.setTimestamps(io, .{
        .access_timestamp = .{ .new = modified },
        .modify_timestamp = .{ .new = modified },
    });
}

//
// The path --verbose prints as the path for storage operations: createStorage (storage-factory.ts) converts its
// backslashes to forward slashes, so a Windows path is printed with forward slashes.
//
fn storageOperationsPath(allocator: std.mem.Allocator, directory: []const u8) ![]const u8 {
    const forwardSlashPath = try allocator.dupe(u8, directory);
    std.mem.replaceScalar(u8, forwardSlashPath, '\\', '/');
    return forwardSlashPath;
}

test "hash prints the hash, date and size of a file like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const file = try node_path.join(allocator, &.{ root, "test.jpg" });
    try std.Io.Dir.cwd().copyFile("../../test/test.jpg", std.Io.Dir.cwd(), file, std.testing.io, .{});
    try setHashTestModifiedTime(file);

    const report = "Hash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c\nDate: 2024-01-02 03:04:05\nSize: 2049800 bytes\n";
    const expected = try std.fmt.allocPrint(allocator, "File: {s}\n{s}", .{ file, report });
    try expectResult(try runZig(allocator, environment, &.{ "hash", file }), expected, "", 0);

    // --verbose first shows the storage the file is read from: the directory of the file.
    const expectedVerbose = try std.fmt.allocPrint(allocator, "Storage type: fs\nPath for storage operations: {s}\nFile: {s}\n{s}", .{ try storageOperationsPath(allocator, root), file, report });
    try expectResult(try runZig(allocator, environment, &.{ "hash", "--verbose", file, "--yes" }), expectedVerbose, "", 0);

    // The file path is printed as it was given, with its prefix.
    const prefixed = try std.fmt.allocPrint(allocator, "fs:{s}", .{file});
    const expectedPrefixed = try std.fmt.allocPrint(allocator, "File: {s}\n{s}", .{ prefixed, report });
    try expectResult(try runZig(allocator, environment, &.{ "hash", prefixed }), expectedPrefixed, "", 0);
}

test "hash reports a file that is not there like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const missing = try node_path.join(allocator, &.{ root, "missing.jpg" });
    try expectResult(try runZig(allocator, environment, &.{ "hash", missing }), "", try std.fmt.allocPrint(allocator, "File not found: {s}\n", .{missing}), 1);

    // A file in a directory that is not there, and a directory, are not found either.
    const inMissingDirectory = try node_path.join(allocator, &.{ root, "nodir", "missing.jpg" });
    try expectResult(try runZig(allocator, environment, &.{ "hash", inMissingDirectory }), "", try std.fmt.allocPrint(allocator, "File not found: {s}\n", .{inMissingDirectory}), 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash", root }), "", try std.fmt.allocPrint(allocator, "File not found: {s}\n", .{root}), 1);

    // --verbose shows the storage before the file is looked up.
    const expectedVerbose = try std.fmt.allocPrint(allocator, "Storage type: fs\nPath for storage operations: {s}\n", .{try storageOperationsPath(allocator, root)});
    try expectResult(try runZig(allocator, environment, &.{ "hash", "-v", missing }), expectedVerbose, try std.fmt.allocPrint(allocator, "File not found: {s}\n", .{missing}), 1);

    try expectResult(try runZig(allocator, environment, &.{ "hash", "" }), "", "File path is required.\n", 1);
}

test "hash reads an encrypted file through its key like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-hash-encrypted");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try node_path.join(allocator, &.{ root, "db" });
    const encrypted = try runZig(allocator, environment, &.{ "encrypt", "--db", db, "--key", "zig-key", "--generate-key", "--yes" });
    try expectResult(encrypted, "\n✅ Encrypted 11 files, 0 were already encrypted.\n", "", 0);
    const assetDirectory = try node_path.join(allocator, &.{ db, "asset" });
    const asset = try node_path.join(allocator, &.{ assetDirectory, "89171cd9-a652-4047-b869-1154bf2c95a1" });
    try setHashTestModifiedTime(asset);

    // With the key the hash is of the decrypted file, the hash of test/dbs/v6's asset, while the size is still the
    // size of the stored (encrypted) file.
    const report = try std.fmt.allocPrint(allocator, "File: {s}\nHash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c\nDate: 2024-01-02 03:04:05\nSize: 2050380 bytes\n", .{asset});
    try expectResult(try runZig(allocator, environment, &.{ "hash", "--key", "zig-key", asset }), report, "", 0);
    const expectedVerbose = try std.fmt.allocPrint(allocator, "Storage type: encrypted-fs\nPath for storage operations: {s}\n{s}", .{ try storageOperationsPath(allocator, assetDirectory), report });
    try expectResult(try runZig(allocator, environment, &.{ "hash", "-k", "zig-key", "-v", asset }), expectedVerbose, "", 0);

    // Without the key, or with a key that is not in the vault, the stored bytes are hashed as they are.
    const stored = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, asset, allocator, .unlimited);
    var storedHash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(stored, &storedHash, .{});
    const storedReport = try std.fmt.allocPrint(allocator, "File: {s}\nHash: {s}\nDate: 2024-01-02 03:04:05\nSize: 2050380 bytes\n", .{ asset, &std.fmt.bytesToHex(storedHash, .lower) });
    try expectResult(try runZig(allocator, environment, &.{ "hash", asset }), storedReport, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash", "--key", "missing", asset }), storedReport, "", 0);

    // A plain file is read as it is through the key too.
    const file = try node_path.join(allocator, &.{ root, "test.jpg" });
    try std.Io.Dir.cwd().copyFile("../../test/test.jpg", std.Io.Dir.cwd(), file, std.testing.io, .{});
    try setHashTestModifiedTime(file);
    const plainReport = try std.fmt.allocPrint(allocator, "File: {s}\nHash: 426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c\nDate: 2024-01-02 03:04:05\nSize: 2049800 bytes\n", .{file});
    try expectResult(try runZig(allocator, environment, &.{ "hash", "--key", "zig-key", file }), plainReport, "", 0);
}

//
// The report toolsCommand (apps/cli/src/cmd/tools.ts) prints before the status of the tools.
//
const tools_report_header = "\n📦 Media Processing Tools Status\n\nTool Status:\n\n";

//
// The report of `psi tools` when no tool is found, up to the installation instructions.
//
const tools_none_available_report = tools_report_header ++
    \\❌ ImageMagick: Not found
    \\   Image processing - resizing, format conversion, metadata extraction
    \\
    \\❌ ffmpeg: Not found
    \\   Video processing - format conversion and thumbnail extraction
    \\
    \\❌ ffprobe: Not found
    \\   Video analysis - metadata extraction, duration, dimensions, codecs
    \\
    \\⚠️ 3 tool(s) missing: ImageMagick, ffmpeg, ffprobe
    \\
    \\
;

//
// The heading showInstallationInstructions (apps/cli/src/lib/installation-instructions.ts) starts with.
//
const tools_instructions_heading = "\nInstallation Instructions:\n\n";

//
// The line showInstallationInstructions ends with.
//
const tools_instructions_ending = "\nAfter installation, run this command again to verify all tools are available.\n";

//
// Replaces what differs between machines in the report of `psi tools`: the kind of ImageMagick found (in its
// name) and the version of each tool found.
//
fn maskToolVersions(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var masked: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try masked.append(allocator, '\n');
        }
        first = false;
        var maskedLine = line;
        for ([_][]const u8{ "ImageMagick (convert/identify)", "ImageMagick (magick)" }) |imageMagickName| {
            maskedLine = try std.mem.replaceOwned(u8, allocator, maskedLine, imageMagickName, "ImageMagick (<kind>)");
        }
        const versionLabel = ": Available (v";
        if (std.mem.indexOf(u8, maskedLine, versionLabel)) |position| {
            if (std.mem.endsWith(u8, maskedLine, ")")) {
                maskedLine = try std.mem.concat(allocator, u8, &.{ maskedLine[0 .. position + versionLabel.len], "<version>)" });
            }
        }
        try masked.appendSlice(allocator, maskedLine);
    }
    return masked.items;
}

//
// Copies the executable of a tool found on the PATH of the environment into the directory, failing when it is
// not on the PATH.
//
fn copyToolFromPath(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, toolName: []const u8, destDir: []const u8) !void {
    const fileName = try std.mem.concat(allocator, u8, &.{ toolName, builtin.os.tag.exeFileExt(builtin.cpu.arch) });
    var pathDirs = std.mem.splitScalar(u8, environment.get("PATH").?, std.fs.path.delimiter);
    while (pathDirs.next()) |pathDir| {
        if (pathDir.len == 0) {
            continue;
        }
        const candidate = try std.fs.path.join(allocator, &.{ pathDir, fileName });
        std.Io.Dir.cwd().access(std.testing.io, candidate, .{}) catch {
            continue;
        };
        try std.Io.Dir.cwd().copyFile(candidate, std.Io.Dir.cwd(), try std.fs.path.join(allocator, &.{ destDir, fileName }), std.testing.io, .{});
        return;
    }
    std.debug.print("This test needs {s} on the PATH.\n", .{toolName});
    return error.RequiredToolMissing;
}

//
// Runs the Zig CLI with the arguments, writing the keys to its stdin (a pipe) and then closing it. TERM is set to
// a terminal that isUnicodeSupported (apps/cli/src/lib/clack/prompts/common.ts) accepts on every platform, so
// the prompts render the same symbols everywhere.
//
fn runZigWithInput(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, keys: []const u8) !helpers.CliResult {
    const terminalEnvironment = try allocator.create(std.process.Environ.Map);
    terminalEnvironment.* = try environment.clone(allocator);
    try terminalEnvironment.put("TERM", "xterm-256color");
    const io = std.testing.io;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigCliPath(allocator));
    try argv.appendSlice(allocator, args);
    const cliDir = try std.Io.Dir.cwd().openDir(io, "../cli", .{});
    defer cliDir.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cliDir },
        .environ_map = terminalEnvironment,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, keys);
    child.stdin.?.close(io);
    child.stdin = null;

    var multiReaderBuffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multiReader: std.Io.File.MultiReader = undefined;
    multiReader.init(allocator, io, multiReaderBuffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multiReader.deinit();
    while (true) {
        multiReader.fill(64, .none) catch |err| {
            if (err == error.EndOfStream) {
                break;
            }
            return err;
        };
    }
    try multiReader.checkAnyError();
    const term = try child.wait(io);
    const exitCode: u8 = switch (term) {
        .exited => |code| code,
        else => 255,
    };
    return .{
        .exitCode = exitCode,
        .stdout = try multiReader.toOwnedSlice(0),
        .stderr = try multiReader.toOwnedSlice(1),
    };
}

//
// Gives the CLI environment a PATH holding only a new, empty directory under the root, and returns the directory.
//
fn usePathOfEmptyDirectory(allocator: std.mem.Allocator, environment: *std.process.Environ.Map, root: []const u8) ![]const u8 {
    const binDir = try std.fs.path.join(allocator, &.{ root, "bin" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, binDir);
    try environment.put("PATH", binDir);
    return binDir;
}

test "tools reports every tool available like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-tools-available");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    for ([_][]const []const u8{ &.{ "tools", "--yes" }, &.{"tools"}, &.{ "tools", "-y" } }) |args| {
        const result = try runZig(allocator, environment, args);
        if (result.exitCode != 0) {
            std.debug.print("This test needs ImageMagick and ffmpeg installed. psi tools printed:\n{s}\n", .{result.stdout});
        }
        const masked: helpers.CliResult = .{
            .exitCode = result.exitCode,
            .stdout = try maskToolVersions(allocator, result.stdout),
            .stderr = result.stderr,
        };

        // The versions are masked by maskToolVersions.
        try expectResult(masked, tools_report_header ++
            \\✅ ImageMagick (<kind>): Available (v<version>)
            \\   Image processing - resizing, format conversion, metadata extraction
            \\
            \\✅ ffmpeg: Available (v<version>)
            \\   Video processing - format conversion and thumbnail extraction
            \\
            \\✅ ffprobe: Available (v<version>)
            \\   Video analysis - metadata extraction, duration, dimensions, codecs
            \\
            \\🎉 All tools are available and ready to use!
            \\
        , "", 0);
    }
}

test "tools --yes reports the missing tools and shows the installation instructions like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-tools-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    _ = try usePathOfEmptyDirectory(allocator, environment, root);

    const result = try runZig(allocator, environment, &.{ "tools", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings("", result.stderr);

    // The installation instructions differ by platform (installation-instructions.test.zig checks them), so
    // only their heading and ending are checked here.
    const report = result.stdout[0..@min(tools_none_available_report.len, result.stdout.len)];
    try std.testing.expectEqualStrings(tools_none_available_report, report);
    const instructions = result.stdout[report.len..];
    try std.testing.expect(std.mem.startsWith(u8, instructions, tools_instructions_heading));
    try std.testing.expect(std.mem.endsWith(u8, instructions, tools_instructions_ending));
}

test "tools names the one missing tool like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-tools-no-imagemagick");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    // A PATH with ffmpeg and ffprobe but no ImageMagick.
    const toolsEnvironment = try allocator.create(std.process.Environ.Map);
    toolsEnvironment.* = try environment.clone(allocator);
    const binDir = try usePathOfEmptyDirectory(allocator, toolsEnvironment, root);
    try copyToolFromPath(allocator, environment, "ffmpeg", binDir);
    try copyToolFromPath(allocator, environment, "ffprobe", binDir);

    const result = try runZig(allocator, toolsEnvironment, &.{ "tools", "--yes" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings("", result.stderr);
    const expectedReport = tools_report_header ++
        \\❌ ImageMagick: Not found
        \\   Image processing - resizing, format conversion, metadata extraction
        \\
        \\✅ ffmpeg: Available (v<version>)
        \\   Video processing - format conversion and thumbnail extraction
        \\
        \\✅ ffprobe: Available (v<version>)
        \\   Video analysis - metadata extraction, duration, dimensions, codecs
        \\
        \\⚠️ 1 tool(s) missing: ImageMagick
        \\
        \\
    ;
    const masked = try maskToolVersions(allocator, result.stdout);
    const report = masked[0..@min(expectedReport.len, masked.len)];
    try std.testing.expectEqualStrings(expectedReport, report);
    const instructions = masked[report.len..];
    try std.testing.expect(std.mem.startsWith(u8, instructions, tools_instructions_heading));
    try std.testing.expect(std.mem.endsWith(u8, instructions, tools_instructions_ending));

    // Only ImageMagick is missing, so the instructions do not mention ffmpeg.
    try std.testing.expect(std.mem.indexOf(u8, instructions, "ffmpeg") == null);
}

test "tools asks before showing the installation instructions like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-tools-declined");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    _ = try usePathOfEmptyDirectory(allocator, environment, root);

    // The confirm prompt answered with "n", as it renders to an input that is not a TTY in a terminal with Unicode
    // (runZigWithInput sets TERM for that), then the message printed when the instructions are declined.
    const declined = try runZigWithInput(allocator, environment, &.{"tools"}, "n");
    try expectResult(declined, tools_none_available_report ++
        "\x1b[?25l \n◆  Would you like to see installation instructions?\n   ● Yes / ○ No\n \n\x1b[1A\n" ++
        "\x1b[?25h\x1b[999D\x1b[4A\x1b[1B\x1b[J◇  Would you like to see installation instructions?\n   No\n\n" ++
        "Please install the missing tools and try again.\n", "", 1);

    // Answering yes shows the installation instructions after the prompt.
    const accepted = try runZigWithInput(allocator, environment, &.{"tools"}, "y");
    try std.testing.expectEqual(@as(u8, 1), accepted.exitCode);
    try std.testing.expectEqualStrings("", accepted.stderr);
    try std.testing.expect(std.mem.startsWith(u8, accepted.stdout, tools_none_available_report ++ "\x1b[?25l \n◆  Would you like to see installation instructions?\n"));
    try std.testing.expect(std.mem.indexOf(u8, accepted.stdout, "◇  Would you like to see installation instructions?\n   Yes\n" ++ tools_instructions_heading) != null);
    try std.testing.expect(std.mem.endsWith(u8, accepted.stdout, tools_instructions_ending));
}

//
// The "Next steps" checkCommand (apps/cli/src/cmd/check.ts) prints after the summary, <db> standing for the
// database path. The first step is only printed when there are files to add.
//
fn checkNextSteps(allocator: std.mem.Allocator, hasFilesToAdd: bool) ![]const u8 {
    const addStep =
        \\    # Add the new files found to your database
        \\    psi add <paths> --db <db>
        \\
        \\
    ;
    const otherSteps =
        \\    # Verify the integrity of all files in the database
        \\    psi verify --db <db>
        \\
        \\    # View database summary and statistics
        \\    psi summary --db <db>
        \\
    ;
    return std.mem.concat(allocator, u8, &.{ "\nNext steps:\n", if (hasFilesToAdd) addStep else "", otherSteps });
}

//
// Creates a test root with a copy of test/dbs/v6 and points the hash cache at the root, so a check does not write
// to the cache of the user running the tests.
//
fn setupCheck(allocator: std.mem.Allocator, name: []const u8) !*std.process.Environ.Map {
    const root = try setup(allocator, name);
    const environment = try helpers.cliEnvironment(allocator, root);
    try environment.put("PHOTOSPHERE_CACHE_DIR", try std.fmt.allocPrint(allocator, "{s}/cache", .{root}));
    return environment;
}

test "check reports which files are already in the database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const environment = try setupCheck(allocator, "cmd-check");
    const root = std.fs.path.dirname(environment.get("PHOTOSPHERE_CACHE_DIR").?).?;
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // test/dbs/v6 holds test.jpg (its one asset) and not test.png.
    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "check", "--db", db, "../../test/test.jpg", "../../test/test.png", "--yes" }), db, "<db>");
    const expected = try std.mem.concat(allocator, u8, &.{
        \\Checked 2 files.
        \\
        \\Summary:
        \\Files considered: 2
        \\Files to add:     1
        \\Files ignored:    0
        \\Files failed:     0
        \\Already added:    1
        \\
        ,
        try checkNextSteps(allocator, true),
    });
    try expectResult(result, expected, "", 0);

    // With the alias, and nothing left to add.
    const known = try normalize(allocator, try runZig(allocator, environment, &.{ "chk", "--db", db, "../../test/test.jpg", "--yes" }), db, "<db>");
    const expectedKnown = try std.mem.concat(allocator, u8, &.{
        \\Checked 1 files.
        \\
        \\Summary:
        \\Files considered: 1
        \\Files to add:     0
        \\Files ignored:    0
        \\Files failed:     0
        \\Already added:    1
        \\
        ,
        try checkNextSteps(allocator, false),
    });
    try expectResult(known, expectedKnown, "", 0);
}

test "check scans a directory like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const environment = try setupCheck(allocator, "cmd-check-directory");
    const root = std.fs.path.dirname(environment.get("PHOTOSPHERE_CACHE_DIR").?).?;
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // test/multiple-files holds 2 images and a video, and a zip of 2 more images, none of them in test/dbs/v6.
    const result = try normalize(allocator, try runZig(allocator, environment, &.{ "check", "--db", db, "../../test/multiple-files", "--yes" }), db, "<db>");
    const expected = try std.mem.concat(allocator, u8, &.{
        \\Checked 5 files.
        \\
        \\Summary:
        \\Files considered: 5
        \\Files to add:     5
        \\Files ignored:    0
        \\Files failed:     0
        \\Already added:    0
        \\
        ,
        try checkNextSteps(allocator, true),
    });
    try expectResult(result, expected, "", 0);
}

test "check reports a file it cannot hash like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const environment = try setupCheck(allocator, "cmd-check-failed");
    const root = std.fs.path.dirname(environment.get("PHOTOSPHERE_CACHE_DIR").?).?;
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const broken = try std.fmt.allocPrint(allocator, "{s}/broken.png", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = broken,
        .data = "not an image",
    });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "check", "--db", db, broken, "../../test/test.jpg", "--yes" }), db, "<db>");
    result.stdout = try withoutErrorLogLine(allocator, result.stdout);

    // The log file is named after the time it was created, so only its directory is checked.
    const logLabel = "Check the log file for details:\n    ";
    const logStart = (std.mem.indexOf(u8, result.stdout, logLabel) orelse {
        return error.LogFileLineMissing;
    }) + logLabel.len;
    const logEnd = std.mem.indexOfScalarPos(u8, result.stdout, logStart, '\n').?;
    // The CLI environment sets the temp directory to <root>/tmp, and the CLI joins the rest on with the separator
    // of the platform.
    const logDir = try std.fs.path.join(allocator, &.{ try std.fmt.allocPrint(allocator, "{s}/tmp", .{root}), "photosphere", "logs" });
    try std.testing.expect(std.mem.startsWith(u8, result.stdout[logStart..logEnd], logDir));
    const stdout = try std.mem.concat(allocator, u8, &.{ result.stdout[0..logStart], "<log file>", result.stdout[logEnd..] });

    const expected = try std.mem.concat(allocator, u8, &.{
        \\Checked 1 files.
        \\
        \\Summary:
        \\Files considered: 2
        \\Files to add:     0
        \\Files ignored:    0
        \\Files failed:     1
        \\Already added:    1
        \\
        \\⚠️  1 file failed. Check the log file for details:
        \\    <log file>
        \\
        ,
        try checkNextSteps(allocator, false),
        // The blank line printed before the error log line, which is removed above.
        "\n",
    });
    try std.testing.expectEqualStrings(expected, stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);

    // What the image tools say about the file differs between platforms, so only the line checkPaths
    // (packages/node-api/src/lib/check.ts) writes is checked.
    const failedLine = try std.fmt.allocPrint(allocator, "Failed to get hash for file {s}\n", .{broken});
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, failedLine));
}

test "check reports a missing database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-check-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{root});
    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "check", "--db", missing, "../../test/test.jpg", "--yes" }), missing, "<missing>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);
    try expectResult(result, verify_missing_report, "", 1);
}

//
// The help of the program: `psi help` and `psi --help` of apps/cli/index.ts, with the main examples and the resources.
//
const program_help =
    \\Usage: psi [options] [command]
    \\
    \\The Photosphere CLI tool for managing your media file database.
    \\
    \\Options:
    \\  --version                                      output the version number
    \\  --debug                                        Enable debug REST API server
    \\  -q, --quiet                                    Suppress optional output (update and news notifications). Give it before the command name.
    \\  -h, --help                                     display help for command
    \\
    \\Commands:
    \\  add|a [options] [files...]                     Adds files and directories to the media file database, once or by watching for more.
    \\  bug [options]                                  Generates a bug report for GitHub with system information and logs.
    \\  check|chk [options] <files...>                 Checks files and directories to see what has already been added to the media file database.
    \\  compare|cmp [options]                          Compares two databases to find the differences between them.
    \\  examples [options]                             Shows usage examples for all CLI commands.
    \\  export|exp [options] <asset-id> <output-path>  Exports an asset by ID to a specified path.
    \\  find-orphans [options]                         Find and list files that are no longer in the merkle tree.
    \\  hash [options] <file-path>                     Compute the hash of a file using the same algorithm as the database.
    \\  debug                                          Debug commands for inspecting database internals.
    \\  help [command]                                 Display help for command
    \\  info|inf [options] <files...>                  Displays detailed information about media files including EXIF data, metadata, and technical specifications.
    \\  init|i [options]                               Initializes a new media file database.
    \\  origin [options]                               Shows the origin database path (from .db/config.json).
    \\  set-origin [options] <path>                    Sets the origin database path in .db/config.json (used as default --dest or --source for sync, replicate, repair, compare).
    \\  consolidate [options] <remote>                 Joins this database to a remote one so the two can sync, creating the remote when it does not exist and recording it as the origin.
    \\  list|ls [options]                              Lists all files in the database sorted by date (newest first) with pagination.
    \\  mcp [options]                                  Start an MCP server (stdio transport). The MCP client chooses which database to open at runtime via list_databases / open_database.
    \\  news                                           Displays the latest update notification and all news items from the Photosphere feed.
    \\  remove|rm [options] <asset-id>                 Removes an asset from the database by ID, deleting the files for the asset.
    \\  remove-orphans [options]                       Find and remove files that are no longer in the merkle tree.
    \\  repair [options]                               Repairs the integrity of the media file database by restoring files from a source database.
    \\  root-hash [options]                            Displays the aggregate root hash of the database.
    \\  database-id [options]                          Displays the database ID (UUID) of the database.
    \\  replicate|rep [options]                        Replicates an asset database from source to destination location.
    \\  summary|sum [options]                          Displays a summary of the media file database including total files, size, and tree hash.
    \\  sync [options]                                 Synchronize changes between two databases, once or by watching for more.
    \\  tools [options]                                Checks for required media processing tools (ImageMagick, ffmpeg, ffprobe).
    \\  upgrade [options]                              Upgrades a media file database to the latest version.
    \\  verify|ver [options]                           Verifies the integrity of the media file database by checking file hashes.
    \\  version                                        Displays version information for psi and its dependencies.
    \\  encrypt [options]                              Encrypts the database in place (plain → encrypted, re-encrypt with new key, or old-format → new format).
    \\  decrypt [options]                              Decrypts the encrypted database in place (removes encryption; deletes .db/encryption.pub).
    \\  secrets|sec                                    Manage secrets stored in the Photosphere secrets store.
    \\  dbs|d                                          Manage the list of configured databases.
    \\
    \\
    \\Getting help:
    \\  psi <command> --help    Shows help for a particular command.
    \\  psi --help              Shows help for all commands.
    \\
    \\Examples:
    \\  psi init --db ./photos                         Creates a new database in the ./photos directory.
    \\  psi add --db ./photos ~/Pictures               Adds all media files from ~/Pictures to the database.
    \\  psi summary --db ./photos                      Shows the database summary (file count, size, etc.).
    \\  psi verify --db ./photos                       Verifies the database integrity.
    \\  psi replicate --db ./photos --dest ./backup    Replicates one database to a backup location.
    \\  psi sync --db ./photos --dest ./backup         Synchronizes changes between two databases.
    \\  psi compare --db ./photos --dest ./backup      Compares two databases for differences.
    \\
    \\Resources:
    \\  🚀 Getting Started: https://github.com/ashleydavis/photosphere/wiki/Getting-Started
    \\  📖 Command Reference: https://github.com/ashleydavis/photosphere/wiki/Command-Reference
    \\  📚 Wiki: https://github.com/ashleydavis/photosphere/wiki
    \\  🐛 View Issues: https://github.com/ashleydavis/photosphere/issues
    \\  ➕ New Issue: https://github.com/ashleydavis/photosphere/issues/new
    \\
;

//
// The listing of `psi examples` (apps/cli/src/cmd/examples.ts).
//
const examples_listing =
    \\📖 Photosphere CLI Examples
    \\
    \\Below are usage examples for all available commands:
    \\
    \\Database Management:
    \\
    \\  init:
    \\    psi init --db .                  Creates a database in current directory.
    \\    psi init --db ./photos           Creates a database in ./photos directory.
    \\
    \\  add:
    \\    psi add --db ./photos ~/Pictures Adds all files from ~/Pictures to the database.
    \\    psi add --db ./photos image.jpg video.mp4 Adds specific files to the database.
    \\    psi add --db ./photos ~/Downloads/photos Adds a directory recursively.
    \\
    \\  check:
    \\    psi check --db ./photos ~/Pictures Checks which files from ~/Pictures are already in database.
    \\    psi check --db ./photos image.jpg Checks if the specific file is already in database.
    \\    psi check --db ./photos ~/Downloads Checks the directory to see what's already been added.
    \\
    \\  summary:
    \\    psi summary --db .               Shows a summary for the database in current directory.
    \\    psi summary --db ./photos        Shows summary for the database in the ./photos directory.
    \\
    \\  verify:
    \\    psi verify --db .                Verifies a database in the current directory.
    \\    psi verify --db ./photos         Verifies a database in the ./photos directory.
    \\    psi verify --db ./photos --full  Forces full verification of all files.
    \\
    \\  find-orphans:
    \\    psi find-orphans --db .          Finds orphaned files in the current directory database.
    \\    psi find-orphans --db ./photos   Finds orphaned files in the ./photos database.
    \\
    \\  remove-orphans:
    \\    psi remove-orphans --db .        Removes orphaned files from the current directory database.
    \\    psi remove-orphans --db ./photos Removes orphaned files from the ./photos database.
    \\    psi remove-orphans --db ./photos --yes Removes orphaned files without confirmation prompt.
    \\
    \\Backup and syncrhonization:
    \\
    \\  replicate:
    \\    psi replicate --db ./photos --dest ./backup Replicates a database to a backup location.
    \\    psi replicate --db . --dest s3:bucket/photos Replicates the current database to S3.
    \\
    \\  compare:
    \\    psi compare --db ./photos --dest ./backup Compares an original database with a backup.
    \\    psi compare --db . --dest s3:bucket/photos Compares a local database with an S3 replica.
    \\    psi compare --db ./photos --dest ./backup --full Shows all differences without truncation.
    \\    psi compare --db ./photos --dest ./backup --max 20 Shows up to 20 items in each category.
    \\
    \\Configuration:
    \\
    \\  tools:
    \\    psi tools                        Checks the status of all required media processing tools.
    \\
    \\File Analysis:
    \\
    \\  info:
    \\    psi info photo.jpg               Shows detailed information about a photo.
    \\    psi info photo1.jpg photo2.jpg   Analyzes multiple specific files.
    \\    psi info ~/Pictures              Analyzes all media files in a directory.
    \\    psi info --db ./photos <asset-id> Shows database metadata for an asset by ID.
    \\    psi info --db ./photos <hash>    Shows database metadata for asset(s) with the given hash.
    \\
    \\Help and Support:
    \\
    \\  examples:
    \\    psi examples                     Shows all usage examples categorized by command.
    \\
    \\  bug:
    \\    psi bug                          Generates a bug report and opens it in the browser.
    \\    psi bug --no-browser             Generates a bug report without opening a browser.
    \\
    \\💡 Tip: Use "psi <command> --help" to see detailed help for any specific command.
    \\
    \\
;

test "examples prints the listing of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-examples");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{"examples"}), examples_listing, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "-q", "examples", "--yes" }), examples_listing, "", 0);
}

test "help prints the help of the program like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-help");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{"help"}), program_help, "", 0);
    try expectResult(try runZig(allocator, environment, &.{"--help"}), program_help, "", 0);

    // A name that is no command reports it, then shows the help of the program.
    try expectResult(try runZig(allocator, environment, &.{ "-q", "help", "bogus" }), program_help, "Unknown command: bogus\n", 0);
}

test "help prints the help of a command like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-help-command");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const examplesHelp =
        \\Usage: psi examples [options]
        \\
        \\Shows usage examples for all CLI commands.
        \\
        \\Options:
        \\  -y, --yes   Non-interactive mode. Use command line arguments and defaults.
        \\              (default: false)
        \\  -h, --help  display help for command
        \\
        \\Examples:
        \\  psi examples                     Shows all usage examples categorized by command.
        \\
    ;
    try expectResult(try runZig(allocator, environment, &.{ "help", "examples" }), examplesHelp, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "examples", "--help" }), examplesHelp, "", 0);

    // The secrets group is not created with .exitOverride(), so its help exits through process.exit, with 0.
    const secretsHelp =
        \\Usage: psi secrets|sec [options] [command]
        \\
        \\Manage secrets stored in the Photosphere secrets store.
        \\
        \\Options:
        \\  -h, --help         display help for command
        \\
        \\Commands:
        \\  add [options]      Interactively add a new secret.
        \\  list|l             List all secrets (values are masked).
        \\  view|v [options]   Show the full value of a named secret.
        \\  edit|e [options]   Edit an existing secret, field by field.
        \\  remove [options]   Remove a named secret.
        \\  clear [options]    Remove all secrets.
        \\  import [options]   Import a PEM private key file as an encryption key.
        \\  send [options]     Send a secret to another device over the local network.
        \\  receive [options]  Receive a secret from another device over the local
        \\                     network.
        \\  help [command]     display help for command
        \\
    ;
    try expectResult(try runZig(allocator, environment, &.{ "help", "secrets" }), secretsHelp, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "help", "sec" }), secretsHelp, "", 0);

    // Run without a subcommand, the group shows its help on stderr and exits with 1.
    try expectResult(try runZig(allocator, environment, &.{"secrets"}), "", secretsHelp, 1);
}

test "commands that are not ported yet fail with an error that names them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-not-ported");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const bugHint = "\nIf you believe this behaviour is a bug, please report it with the following command:\n   psi bug\n";
    try expectResult(try runZig(allocator, environment, &.{ "-q", "dbs", "view", "--name", "x" }), bugHint, "An unknown error occurred\nError: The dbs view command is not ported to the Zig CLI yet.\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "-q", "news" }), bugHint, "An unknown error occurred\nError: The news command is not ported to the Zig CLI yet.\n", 1);
}

//
// The vault the secrets tests start with (written as the plaintext vault's vault.json): S3 credentials and a plain
// secret.
//
const secrets_seed_vault =
    \\{"s3a":{"name":"s3a","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\"}"},"my-secret":{"name":"my-secret","type":"plain","value":"hello"}}
;

//
// Creates a test root whose plaintext vault holds secrets_seed_vault, and returns its environment.
//
fn setupSecrets(allocator: std.mem.Allocator, root: []const u8) !*std.process.Environ.Map {
    const environment = try helpers.cliEnvironment(allocator, root);
    const vaultDir = try std.fmt.allocPrint(allocator, "{s}/vault", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, vaultDir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/vault.json", .{vaultDir}), .data = secrets_seed_vault });
    return environment;
}

//
// The environment of the hash-cache tests: the CLI test environment with the cache in <root>/cache, so the
// test's hash caches are its own.
//
fn hashCacheEnvironment(allocator: std.mem.Allocator, root: []const u8) !*std.process.Environ.Map {
    const environment = try helpers.cliEnvironment(allocator, root);
    try environment.put("PHOTOSPHERE_CACHE_DIR", try std.fs.path.join(allocator, &.{ root, "cache" }));
    return environment;
}

//
// The rule under the header of `psi secrets list` (80 box-drawing characters).
//
const secrets_list_rule = "\u{2500}" ** 80;

test "secrets list, view and remove print the reports of the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-secrets");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setupSecrets(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "list" }), "\nName                                     Type                 Value\n" ++ secrets_list_rule ++ "\ns3a                                      s3-credentials       ****\nmy-secret                                plain                ****\n\n", "", 0);

    // S3 credentials are shown field by field.
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--name", "s3a", "--yes" }), "\nName: s3a\nType: s3-credentials\nValue:\n  region: us-east-1\n  accessKeyId: AK\n\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "s", "v", "--name", "my-secret", "--yes" }), "\nName: my-secret\nType: plain\nValue: hello\n\n", "", 0);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "remove", "--name", "my-secret", "--yes" }), "\n\u{2713} Secret \"my-secret\" deleted.\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "sec", "ls" }), "\nName                                     Type                 Value\n" ++ secrets_list_rule ++ "\ns3a                                      s3-credentials       ****\n\n", "", 0);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "clear", "--yes" }), "\n\u{2713} Deleted 1 secret(s).\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "list" }), "No secrets found.\n", "", 0);
}

// Ported from apps/cli/src/test/cmd/secrets.test.ts: "secretsView --raw writes only the bare value to stdout" and
// "without --raw the value is logged with labels rather than written to stdout".
test "secrets view --raw writes only the bare value, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-secrets-raw");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const multiLineValue = "-----BEGIN PRIVATE KEY-----\nABC\n-----END PRIVATE KEY-----";
    const keyFile = try std.fmt.allocPrint(allocator, "{s}/enc.key", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = keyFile, .data = multiLineValue });
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "import", "--yes", "--private-key", keyFile }), "\u{2713} Key imported as \"enc\".\n", "", 0);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--name", "enc", "--yes", "--raw" }), multiLineValue, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--name", "enc", "--yes" }), "\nName: enc\nType: encryption-key\nValue: " ++ multiLineValue ++ "\n\n", "", 0);
}

// Ported from apps/cli/src/test/cmd/secrets.test.ts: the "logs Did you mean hint when secret not found and
// suggestions exist" tests of secretsView, secretsEdit, secretsRemove and secretsSend, and "does not log hint when no
// suggestions exist".
test "secrets view, edit, remove and send suggest similar names for a missing secret like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-secrets-similar");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try setupSecrets(allocator, root);
    const hint = "Did you mean:\n  \u{2022} my-secret\n";
    const notFound = "\u{2717} No secret named \"my-secrt\" found.\n";

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "my-secrt" }), hint, notFound, 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "my-secrt", "--value", "x" }), hint, notFound, 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "remove", "--yes", "--name", "my-secrt" }), hint, notFound, 1);
    const sendResult = try runZig(allocator, environment, &.{ "secrets", "send", "--yes", "--name", "my-secrt" });
    try std.testing.expect(std.mem.endsWith(u8, sendResult.stdout, "   This does not work over the internet.                              \n" ++ (" " ** 70) ++ "\n" ++ hint));
    try std.testing.expectEqualStrings(notFound, sendResult.stderr);
    try std.testing.expectEqual(@as(u8, 1), sendResult.exitCode);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "zzzzzzzzzzzzzz" }), "", "\u{2717} No secret named \"zzzzzzzzzzzzzz\" found.\n", 1);
}

// Ported from apps/cli/src/test/cmd/secrets.test.ts: "secretsSend does not call findSimilarSecretNames when no name
// is provided".
test "secrets send with no name and no secrets says so like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-secrets-send-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const expected =
        \\
        \\Send Secret
        \\   ℹ Network Requirement
        \\                                                                      
        \\   Both devices must be on the same local network (wired or Wi-Fi).   
        \\   This does not work over the internet.                              
        \\                                                                      
        \\No secrets found.
        \\Use "psi secrets add" to add a secret first.
        \\
    ;
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "send", "--yes" }), expected, "", 0);
}

test "secrets add and edit store and change secrets like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-secrets-add");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "  test-secret ", "--type", "plain", "--value", "hello123" }), "\u{2713} Secret \"test-secret\" added.\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "test-secret", "--type", "plain", "--value", "x" }), "", "\u{2717} A secret named \"test-secret\" already exists. Use \"secrets edit\" to update it.\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "other" }), "", "\u{2717} --name, --type, and --value are required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "add", "--yes", "--name", "other", "--type", "bogus", "--value", "v" }), "", "\u{2717} Invalid secret type \"bogus\". Must be one of: api-key, s3-credentials, encryption-key, plain\n", 1);

    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "test-secret" }), "", "\u{2717} --new-name, --value, or --value-file is required with --yes\n", 1);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "test-secret", "--value", "updated" }), "\u{2713} Secret \"test-secret\" updated.\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "test-secret", "--new-name", " renamed " }), "\u{2713} Secret \"renamed\" updated.\n", "", 0);
    const valueFile = try std.fmt.allocPrint(allocator, "{s}/value.txt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = valueFile, .data = "line1\nline2\n" });
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "edit", "--yes", "--name", "renamed", "--value-file", valueFile }), "\u{2713} Secret \"renamed\" updated.\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "view", "--yes", "--name", "renamed", "--raw" }), "line1\nline2\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "secrets", "list" }), "\nName                                     Type                 Value\n" ++ secrets_list_rule ++ "\nrenamed                                  plain                ****\n\n", "", 0);
}

test "secrets send and receive transfer a secret over the local network like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const senderRoot = try helpers.makeTempDir(allocator, "cmd-secrets-sender");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, senderRoot) catch {};
    const receiverRoot = try helpers.makeTempDir(allocator, "cmd-secrets-receiver");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, receiverRoot) catch {};
    const senderEnvironment = try setupSecrets(allocator, senderRoot);
    const receiverEnvironment = try helpers.cliEnvironment(allocator, receiverRoot);

    // Discovery is machine-wide, so the pairing code is drawn per run: a fixed one could pair with the receiver of
    // another run of this test.
    var randomBytes: [4]u8 = undefined;
    std.testing.io.random(&randomBytes);
    const code = try std.fmt.allocPrint(allocator, "{d}", .{1000 + std.mem.readInt(u32, &randomBytes, .little) % 9000});

    const receiverOutput = try std.fmt.allocPrint(allocator, "{s}/receiver.txt", .{receiverRoot});
    const receiverThread = try std.Thread.spawn(.{}, runReceiver, .{ receiverEnvironment, code, receiverOutput });
    const sendResult = try runZig(allocator, senderEnvironment, &.{ "secrets", "send", "--yes", "--name", "s3a", "--code", code });
    receiverThread.join();

    const sendExpected = try std.fmt.allocPrint(allocator,
        \\
        \\Send Secret
        \\   ℹ Network Requirement
        \\                                                                      
        \\   Both devices must be on the same local network (wired or Wi-Fi).   
        \\   This does not work over the internet.                              
        \\                                                                      
        \\Hint: Run `psi secrets receive` on another device to receive this secret.
        \\
        \\Secret to send:
        \\  Name: s3a
        \\  Type: s3-credentials
        \\
        \\  Pairing code: {s}
        \\  Enter this code on the receiver device, then wait.
        \\
        \\Waiting for receiver on the local network... (Ctrl+C to cancel)
        \\Receiver found!
        \\
        \\✓ Secret sent successfully!
        \\
    , .{code});
    try expectResult(sendResult, sendExpected, "", 0);

    const receiveExpected =
        \\
        \\Receive Secret
        \\   ℹ Network Requirement
        \\                                                                      
        \\   Both devices must be on the same local network (wired or Wi-Fi).   
        \\   This does not work over the internet.                              
        \\                                                                      
        \\Hint: Run `psi secrets send` on another device to send a secret.
        \\Waiting for sender on the local network... (Ctrl+C to cancel)
        \\Payload received!
        \\
        \\Received secret:
        \\  Type: s3-credentials
        \\
        \\
        \\✓ Secret "s3a" imported successfully!
        \\exit 0
    ;
    try std.testing.expectEqualStrings(receiveExpected, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, receiverOutput, allocator, .unlimited));
    try expectResult(try runZig(allocator, receiverEnvironment, &.{ "secrets", "view", "--yes", "--name", "s3a", "--raw" }), "{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\"}", "", 0);
}

//
// Runs `psi secrets receive --yes --code <code>` (the receiving device of the send and receive test) and writes its
// stdout, followed by "exit <code>", to a file.
//
fn runReceiver(environment: *const std.process.Environ.Map, code: []const u8, outputPath: []const u8) void {
    // The test's arena is not thread-safe, so the receiver thread allocates from the process allocator.
    const allocator = std.heap.smp_allocator;
    const result = runZig(allocator, environment, &.{ "secrets", "receive", "--yes", "--code", code }) catch |err| {
        std.debug.panic("Running the receiver failed: {s}", .{@errorName(err)});
    };
    const text = std.fmt.allocPrint(allocator, "{s}{s}exit {d}", .{ result.stdout, result.stderr, result.exitCode }) catch |err| {
        std.debug.panic("Formatting the receiver's output failed: {s}", .{@errorName(err)});
    };
    std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = outputPath, .data = text }) catch |err| {
        std.debug.panic("Writing the receiver's output failed: {s}", .{@errorName(err)});
    };
}

//
// What `psi debug merkle-tree --records` (apps/cli/src/cmd/debug.ts) prints for test/dbs/v6: the aggregate root hash, the
// files tree, the BSON database tree, the tree of its metadata collection and of its one shard, and the one record of
// that shard with its fields cut to 5 by truncateLongStrings.
//
const debug_merkle_tree_v6_records =
    \\
    \\🌳 Merkle Trees Visualization
    \\
    \\Aggregate Root Hash:
    \\============================================================
    \\c18854777b06e1b0d499230db43f74b32bf937cd892c974b673621b979f40590
    \\
    \\Files Merkle Tree (.db/files.dat):
    \\============================================================
    \\Tree Metadata:
    \\  UUID: 85fe592c-9b92-4fa1-9ec5-f87f01cf8e72
    \\  Total Nodes: 7
    \\  Total Items: 4
    \\  Total Size: 2877318 bytes
    \\
    \\Database Metadata:
    \\  filesImported: 1
    \\
    \\Version: 6
    \\
    \\==================================================
    \\Sort Tree:
    \\==================================================
    \\
    \\└── asset/89171cd9-a652-4047-b869-1154bf2c95a1 (7)
    \\    ├── asset/89171cd9-a652-4047-b869-1154bf2c95a1 (3)
    \\    │   ├── asset/89171cd9-a652-4047-b869-1154bf2c95a1 (427c)
    \\    │   └── display/89171cd9-a652-4047-b869-1154bf2c95a1 (8ad9)
    \\    └── README.md (3)
    \\        ├── README.md (94b7)
    \\        └── thumb/89171cd9-a652-4047-b869-1154bf2c95a1 (9ee6)
    \\
    \\==================================================
    \\Merkle Tree:
    \\==================================================
    \\
    \\└──  a9bc
    \\    ├──  dd8f
    \\    │   ├──  427c asset/89171cd9-a652-4047-b869-1154bf2c95a1
    \\    │   └──  8ad9 display/89171cd9-a652-4047-b869-1154bf2c95a1
    \\    └──  e061
    \\        ├──  94b7 README.md
    \\        └──  9ee6 thumb/89171cd9-a652-4047-b869-1154bf2c95a1
    \\
    \\==================================================
    \\Root Hash: a9b73642fdb4367f37ad07a11351aabbc5ef7e9dfe334f0c554171fe84feb9bc
    \\==================================================
    \\
    \\==================================================
    \\Leaf Nodes:
    \\==================================================
    \\asset/89171cd9-a652-4047-b869-1154bf2c95a1 (426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c)
    \\display/89171cd9-a652-4047-b869-1154bf2c95a1 (8a2205c424a91b8b643a11bc4c12529d56517198fa977243bbf26cfcd1a165d9)
    \\README.md (94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7)
    \\thumb/89171cd9-a652-4047-b869-1154bf2c95a1 (9ecd6efc5383fbda3c1125ea06a1311aa6fa9906fb4c8c85362797b8240c36e6)
    \\==================================================
    \\
    \\
    \\BSON Database Merkle Tree (.db/bson/db.dat):
    \\============================================================
    \\Tree Metadata:
    \\  UUID: d9ce4a52-ec73-457b-9fed-6af95e2aaa03
    \\  Total Nodes: 1
    \\  Total Items: 1
    \\  Total Size: 1 bytes
    \\
    \\Database Metadata:
    \\
    \\Version: 6
    \\
    \\==================================================
    \\Sort Tree:
    \\==================================================
    \\
    \\└── metadata (2924)
    \\
    \\==================================================
    \\Merkle Tree:
    \\==================================================
    \\
    \\└──  2924 metadata
    \\
    \\==================================================
    \\Root Hash: 291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224
    \\==================================================
    \\
    \\==================================================
    \\Leaf Nodes:
    \\==================================================
    \\metadata (291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224)
    \\==================================================
    \\
    \\
    \\Collection Merkle Trees:
    \\============================================================
    \\
    \\Collection: metadata
    \\------------------------------------------------------------
    \\Tree Metadata:
    \\  UUID: 3ce192e5-28b1-4694-b5df-dc46b3628ee3
    \\  Total Nodes: 1
    \\  Total Items: 1
    \\  Total Size: 1 bytes
    \\
    \\Database Metadata:
    \\
    \\Version: 6
    \\
    \\==================================================
    \\Sort Tree:
    \\==================================================
    \\
    \\└── 96 (2924)
    \\
    \\==================================================
    \\Merkle Tree:
    \\==================================================
    \\
    \\└──  2924 96
    \\
    \\==================================================
    \\Root Hash: 291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224
    \\==================================================
    \\
    \\==================================================
    \\Leaf Nodes:
    \\==================================================
    \\96 (291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224)
    \\==================================================
    \\
    \\
    \\  Shard: 96
    \\  ----------------------------------------------------------
    \\  Tree Metadata:
    \\    UUID: 210118f1-5567-4e8c-a031-b74167da701b
    \\    Total Nodes: 1
    \\    Total Items: 1
    \\    Total Size: 119935 bytes
    \\  
    \\  Database Metadata:
    \\  
    \\  Version: 6
    \\  
    \\  ==================================================
    \\  Sort Tree:
    \\  ==================================================
    \\  
    \\  └── 89171cd9-a652-4047-b869-1154bf2c95a1 (2924)
    \\  
    \\  ==================================================
    \\  Merkle Tree:
    \\  ==================================================
    \\  
    \\  └──  2924 89171cd9-a652-4047-b869-1154bf2c95a1
    \\  
    \\  ==================================================
    \\  Root Hash: 291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224
    \\  ==================================================
    \\  
    \\  ==================================================
    \\  Leaf Nodes:
    \\  ==================================================
    \\  89171cd9-a652-4047-b869-1154bf2c95a1 (291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224)
    \\  ==================================================
    \\  
    \\
    \\    Records in shard 96:
    \\      89171cd9a6524047b8691154bf2c95a1:
    \\        Hash: 291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224
    \\        {
    \\          "_id": "89171cd9-a652-4047-b869-1154bf2c95a1",
    \\          "fields": {
    \\            "width": 2560,
    \\            "height": 1920,
    \\            "origFileName": "test.jpg",
    \\            "origPath": "../../test",
    \\            "contentType": "image/jpeg",
    \\            "...": "10 more fields"
    \\          },
    \\          "metadata": {}
    \\        }
    \\
    \\
;

test "debug merkle-tree prints the trees and records like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-debug-merkle-tree");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    const result = try runZig(allocator, environment, &.{ "debug", "merkle-tree", "--db", db, "--yes", "--records" });
    try expectResult(result, debug_merkle_tree_v6_records, "", 0);

    // Without --records the output stops before the records of the shard.
    const recordsStart = std.mem.indexOf(u8, debug_merkle_tree_v6_records, "\n    Records in shard 96:").?;
    const withoutRecords = try runZig(allocator, environment, &.{ "debug", "merkle-tree", "--db", db, "--yes" });
    try expectResult(withoutRecords, debug_merkle_tree_v6_records[0 .. recordsStart + 1], "", 0);

    // With --all the record is shown whole: its 16 fields, the long micro thumbnail included.
    const all = try runZig(allocator, environment, &.{ "debug", "merkle-tree", "--db", db, "--yes", "--records", "--all" });
    try std.testing.expectEqual(@as(u8, 0), all.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "\"...\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "            \"photoDate\": \"2025-05-27T09:54:16.000Z\",\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "            \"color\": [\n              112,\n              110,\n              105\n            ]\n") != null);
}

//
// The name of the asset of test/dbs/v6 and of the copy of it the duplicate tests add.
//
const debug_original_asset = "89171cd9-a652-4047-b869-1154bf2c95a1";
const debug_duplicate_asset = "00000000-0000-0000-0000-000000000001";

test "debug finds and removes a duplicate asset, then rebuilds the sort indexes, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try setup(allocator, "cmd-debug-duplicates");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});

    // A second asset file with the same content as the first, both given the same modified time.
    const originalPath = try std.fs.path.join(allocator, &.{ db, "asset", debug_original_asset });
    const duplicatePath = try std.fs.path.join(allocator, &.{ db, "asset", debug_duplicate_asset });
    try std.Io.Dir.cwd().copyFile(originalPath, std.Io.Dir.cwd(), duplicatePath, io, .{});
    try setHashTestModifiedTime(originalPath);
    try setHashTestModifiedTime(duplicatePath);

    const rebuilt = try runZig(allocator, environment, &.{ "debug", "build-files-tree", "--db", db, "--yes" });
    try expectResult(rebuilt, try std.fmt.allocPrint(allocator, "\nRebuilding files merkle tree from storage\n  Database: {s}\n\nRebuilt files merkle tree: 5 files.\n\n", .{db}), "", 0);

    const collisionsPath = try node_path.join(allocator, &.{ db, "collisions.json" });
    const collisions = try runZig(allocator, environment, &.{ "debug", "find-collisions", "--db", db, "--yes" });
    try expectResult(collisions, try std.fmt.allocPrint(allocator, "\nFinding hash collisions in database:\n  Database: {s}\n\n\n📊 Summary\nTotal collisions: 1\nTotal asset IDs in collisions: 2\nOutput file: {s}\n\n", .{ db, collisionsPath }), "", 0);
    try std.testing.expectEqualStrings(
        "{\n  \"426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c\": [\n    {\n      \"assetId\": \"00000000-0000-0000-0000-000000000001\",\n      \"size\": 2049800,\n      \"time\": \"2024-01-02T03:04:05.678Z\"\n    },\n    {\n      \"assetId\": \"89171cd9-a652-4047-b869-1154bf2c95a1\",\n      \"size\": 2049800,\n      \"time\": \"2024-01-02T03:04:05.678Z\"\n    }\n  ]\n}",
        try std.Io.Dir.cwd().readFileAlloc(io, collisionsPath, allocator, .unlimited),
    );

    const duplicatesPath = try node_path.join(allocator, &.{ db, "duplicates.json" });
    const duplicates = try runZig(allocator, environment, &.{ "debug", "find-duplicates", "--db", db, "--yes" });
    try expectResult(duplicates, try std.fmt.allocPrint(allocator, "\nFinding duplicate assets by comparing file sizes:\n  Input file: {s}\n  Database: {s}\n\n\n📊 Summary\nTotal collisions: 1\nTrue duplicates (same content): 1\nHash collisions (different content): 0\nOutput file: {s}\n\n", .{ collisionsPath, db, duplicatesPath }), "", 0);
    try std.testing.expectEqualStrings(
        "{\n  \"426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c\": [\n    {\n      \"assetIds\": [\n        \"00000000-0000-0000-0000-000000000001\",\n        \"89171cd9-a652-4047-b869-1154bf2c95a1\"\n      ]\n    }\n  ]\n}",
        try std.Io.Dir.cwd().readFileAlloc(io, duplicatesPath, allocator, .unlimited),
    );

    // The first asset of each group is kept and the rest are removed: here that is the asset of test/dbs/v6.
    const removed = try runZig(allocator, environment, &.{ "debug", "remove-duplicates", "--db", db, "--yes" });
    try expectResult(removed, try std.fmt.allocPrint(allocator, "\nRemoving duplicate assets:\n  Input file: {s}\n  Database: {s}\n\nFound 1 duplicate asset to remove\n\n\n📊 Summary\nAssets removed: 1\n\n", .{ duplicatesPath, db }), "", 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, originalPath, .{}));
    _ = try std.Io.Dir.cwd().statFile(io, duplicatePath, .{});

    // Nothing is left to remove once the duplicates file lists no group with more than one asset.
    const emptyPath = try node_path.join(allocator, &.{ db, "empty.json" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = emptyPath,
        .data = "{}\n",
    });
    const nothing = try runZig(allocator, environment, &.{ "debug", "remove-duplicates", "--db", db, "--yes", "-i", "empty.json" });
    try expectResult(nothing, try std.fmt.allocPrint(allocator, "\nRemoving duplicate assets:\n  Input file: {s}\n  Database: {s}\n\nNo duplicate assets to remove.\n\n", .{ emptyPath, db }), "", 0);

    const sortIndexes = try runZig(allocator, environment, &.{ "debug", "build-sort-index", "--db", db, "--yes" });
    try expectResult(sortIndexes, try std.fmt.allocPrint(allocator, "\n🔨 Rebuilding Sort Indexes\n  Database: {s}\n\nFound 2 existing sort indexes:\n  - hash (asc)\n  - photoDate (desc)\n\nDeleted 2 sort indexes.\n\nRebuilding sort indexes...\n\n✅ Sort indexes rebuilt successfully.\n\nRebuilt indexes:\n  - hash (asc, string)\n  - photoDate (desc, date)\n\n", .{db}), "", 0);
}

test "debug find-collisions writes an absolute --output path like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try setup(allocator, "cmd-debug-collisions-output");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const outputPath = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    const absoluteOutput = try node_path.join(allocator, &.{ outputPath, "out.json" });

    const result = try runZig(allocator, environment, &.{ "debug", "find-collisions", "--db", db, "--yes", "--output", absoluteOutput });
    try expectResult(result, try std.fmt.allocPrint(allocator, "\nFinding hash collisions in database:\n  Database: {s}\n\n\n📊 Summary\nTotal collisions: 0\nTotal asset IDs in collisions: 0\nOutput file: {s}\n\n", .{ db, absoluteOutput }), "", 0);
    try std.testing.expectEqualStrings("{}", try std.Io.Dir.cwd().readFileAlloc(io, absoluteOutput, allocator, .unlimited));
}

test "debug find-duplicates reports an input file it cannot read like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try setup(allocator, "cmd-debug-duplicates-missing");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const inputPath = try node_path.join(allocator, &.{ db, "collisions.json" });

    const missing = try runZig(allocator, environment, &.{ "debug", "find-duplicates", "--db", db, "--yes" });
    try std.testing.expectEqual(@as(u8, 1), missing.exitCode);
    try std.testing.expectEqualStrings("", missing.stderr);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "Error: Failed to read input file {s}: ENOENT: no such file or directory, open '{s}'\nTemporary files retained for inspection: <session dir>\n", .{ inputPath, inputPath }),
        try maskRetainedSessionDir(allocator, missing.stdout),
    );

    // Bun's JSON.parse names what it found ("Unexpected identifier"); the Zig CLI names the error of the JSON parser,
    // as the other ported JSON.parse calls do.
    const badPath = try node_path.join(allocator, &.{ db, "bad.json" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = badPath,
        .data = "not json\n",
    });
    const malformed = try runZig(allocator, environment, &.{ "debug", "remove-duplicates", "--db", db, "--yes", "-i", "bad.json" });
    try std.testing.expectEqual(@as(u8, 1), malformed.exitCode);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "Error: Failed to read input file {s}: JSON Parse error: SyntaxError\nTemporary files retained for inspection: <session dir>\n", .{badPath}),
        try maskRetainedSessionDir(allocator, malformed.stdout),
    );
}

//
// A hash in hex, as the hash-cache tools take and print it.
//
const hash_cache_test_hash = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

//
// The "bug report" hint handleError (apps/cli/index.ts) prints to stdout after an unknown error.
//
const bug_report_hint = "\nIf you believe this behaviour is a bug, please report it with the following command:\n   psi bug\n";

test "hash-cache tools record, read back and remove entries like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash-cache-tools");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try hashCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    // hashCacheDirCommand (apps/cli/src/cmd/hash-cache-tools.ts) prints getHashCacheDir(db): <cache>/<16 hex digits
    // of the database path's hash>/hash-cache.
    const dirResult = try runZig(allocator, environment, &.{ "hash-cache", "dir", "--db", db });
    const cachePrefix = try std.fmt.allocPrint(allocator, "{s}{c}", .{ try std.fs.path.join(allocator, &.{ root, "cache" }), std.fs.path.sep });
    try std.testing.expect(std.mem.startsWith(u8, dirResult.stdout, cachePrefix));
    try std.testing.expect(std.mem.endsWith(u8, dirResult.stdout, try std.fmt.allocPrint(allocator, "{c}hash-cache\n", .{std.fs.path.sep})));
    try std.testing.expectEqual(cachePrefix.len + 16 + "/hash-cache\n".len, dirResult.stdout.len);
    try std.testing.expectEqualStrings("", dirResult.stderr);
    try std.testing.expectEqual(@as(u8, 0), dirResult.exitCode);

    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "count", "--db", db }), "0\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "list", "--db", db }), "", "", 0);

    // set and set-source print nothing. A length that parseInt cannot read is recorded as 0.
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set", "b/photo.jpg", hash_cache_test_hash, "1234", "--db", db }), "", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set", "a.jpg", hash_cache_test_hash, "abc", "--db", db }), "", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set-source", "source-1", hash_cache_test_hash, "5000000", "--db", db }), "", "", 0);

    // Entries are listed in key order.
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "list", "--db", db }), "a.jpg\nb/photo.jpg\nsource-1\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "count", "--db", db }), "3\n", "", 0);

    // get prints the hash, and a miss prints nothing and exits 1. get-asset-id exits 1 for an entry without an
    // asset id as well as for a missing one.
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "get", "b/photo.jpg", "--db", db }), hash_cache_test_hash ++ "\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "get", "missing.jpg", "--db", db }), "", "", 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "get-asset-id", "b/photo.jpg", "--db", db }), "", "", 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "get-asset-id", "missing.jpg", "--db", db }), "", "", 1);

    // remove exits 1 when there was nothing to remove.
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "remove", "a.jpg", "--db", db }), "", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "remove", "a.jpg", "--db", db }), "", "", 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "list", "--db", db }), "b/photo.jpg\nsource-1\n", "", 0);
}

test "hash-cache set fails like the TypeScript CLI for a hash or length the cache cannot hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash-cache-set-errors");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try hashCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    // Buffer.from(hash, 'hex') stops at the first pair that is not hex, so this hash has no bytes.
    const badHash = try runZig(allocator, environment, &.{ "hash-cache", "set", "a.jpg", "zz" ++ hash_cache_test_hash, "1", "--db", db });
    try expectResult(badHash, bug_report_hint, "An unknown error occurred\nError: Invalid hash length: 0. Expected 32 bytes.\n", 1);

    // The length is written as 6 bytes, and Node's writeUIntLE throws a RangeError for a larger one.
    const tooLong = try runZig(allocator, environment, &.{ "hash-cache", "set", "a.jpg", hash_cache_test_hash, "300000000000000", "--db", db });
    try expectResult(tooLong, bug_report_hint, "An unknown error occurred\nRangeError: The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received 300000000000000\n", 1);

    // A negative length is out of range too.
    const negative = try runZig(allocator, environment, &.{ "hash-cache", "set", "a.jpg", hash_cache_test_hash, "--db", db, "--", "-5" });
    try expectResult(negative, bug_report_hint, "An unknown error occurred\nRangeError: The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received -5\n", 1);

    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "count", "--db", db }), "0\n", "", 0);
}

test "hash-cache hash-file and add hash a file like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash-cache-add");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try hashCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    // The SHA-256 hash of test/test.png. The CLI runs in apps/cli.
    const pngHash = "3d9d6f073e60a13e6706bec322b47615f76b594b17bd64495614996b995908d9";
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "hash-file", "../../test/test.png" }), pngHash ++ "\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "count", "--db", db }), "0\n", "", 0);

    // add records the file under the path it was given.
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "add", "../../test/test.png", "--db", db }), pngHash ++ "\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "list", "--db", db }), "../../test/test.png\n", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "get", "../../test/test.png", "--db", db }), pngHash ++ "\n", "", 0);

    // Bun's createReadStream fails for a missing file with the path resolved against the cwd, and with no stack,
    // so the error shows its message alone.
    const missingPath = try std.fs.path.join(allocator, &.{ root, "missing.png" });
    const expectedError = try std.fmt.allocPrint(allocator, "An unknown error occurred\nENOENT: no such file or directory, open '{s}'\n", .{missingPath});
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "hash-file", missingPath }), bug_report_hint, expectedError, 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "add", missingPath, "--db", db }), bug_report_hint, expectedError, 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "count", "--db", db }), "1\n", "", 0);
}

test "hash-cache show and clear display and clear a database's hash cache like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-hash-cache-show");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try hashCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });
    const dirResult = try runZig(allocator, environment, &.{ "hash-cache", "dir", "--db", db });
    const location = dirResult.stdout[0 .. dirResult.stdout.len - 1];

    const empty = try runZig(allocator, environment, &.{ "hash-cache", "show", "--db", db, "--yes" });
    try expectResult(empty, "\n=== Local Hash Cache ===\nLocal hash cache not found or empty.\n\n", "", 0);

    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set", "b/photo.jpg", hash_cache_test_hash, "1234", "--db", db }), "", "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set-source", "source-1", hash_cache_test_hash, "5000000", "--db", db }), "", "", 0);

    // The tools record a last modified time of 0, and formatBytes (apps/cli/src/lib/format.ts) prints the sizes.
    const shown = try runZig(allocator, environment, &.{ "hash-cache", "show", "--db", db, "--yes" });
    const expectedShown = try std.fmt.allocPrint(allocator,
        \\
        \\=== Local Hash Cache ===
        \\Database: {s}
        \\Location: {s}
        \\Entries: 2
        \\
        \\Cache entries:
        \\
        \\  b/photo.jpg
        \\    Keyed by: file path
        \\    Size: 1.21 KiB
        \\    Modified: 1970-01-01 00:00:00
        \\    Hash: {s}
        \\    Asset id: (not known to be in the database)
        \\
        \\  source-1
        \\    Keyed by: photo library source id
        \\    Size: 4.77 MiB
        \\    Modified: 1970-01-01 00:00:00
        \\    Hash: {s}
        \\    Asset id: (not known to be in the database)
        \\
        \\  Total: 2 entries
        \\
        \\
    , .{ db, location, hash_cache_test_hash, hash_cache_test_hash });
    try expectResult(shown, expectedShown, "", 0);

    const cleared = try runZig(allocator, environment, &.{ "hash-cache", "clear", "--db", db, "--yes" });
    try expectResult(cleared, try std.fmt.allocPrint(allocator, "✓ Cleared hash cache at: {s}\n", .{location}), "", 0);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, location, .{}));

    const clearedAgain = try runZig(allocator, environment, &.{ "hash-cache", "clear", "--db", db, "--yes" });
    try expectResult(clearedAgain, "Local hash cache not found or already empty.\n", "", 0);
}

test "hash-cache commands without --db fail like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-hash-cache-no-db");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try hashCacheEnvironment(allocator, root);

    // Commander's missing mandatory option error is not one main() exits quietly for, so it is rethrown and
    // reported as the CommanderError it is.
    const message = "error: required option '--db <path>' not specified";
    const expectedStderr = message ++ "\nAn unknown error occurred\nCommanderError: " ++ message ++ "\n";
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "list" }), bug_report_hint, expectedStderr, 1);
    try expectResult(try runZig(allocator, environment, &.{ "hash-cache", "set", "a", "b" }), bug_report_hint, expectedStderr, 1);
}
