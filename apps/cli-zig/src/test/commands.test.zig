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
