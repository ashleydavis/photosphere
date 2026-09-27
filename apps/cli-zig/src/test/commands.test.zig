const std = @import("std");
const helpers = @import("test-helpers.zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");

//
// The paths of the two CLIs.
//
const Clis = struct {
    // The Zig binary.
    zig: []const u8,

    // The TypeScript entry point.
    ts: []const u8,
};

//
// Gets the paths of the two CLIs.
//
fn clis(allocator: std.mem.Allocator) !Clis {
    return .{
        .zig = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, helpers.psi_path, allocator),
        .ts = @import("cli-zig").delegate.ts_cli_path,
    };
}

//
// Runs the Zig CLI with the arguments.
//
fn runZig(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, (try clis(allocator)).zig);
    try argv.appendSlice(allocator, args);
    return helpers.runCli(allocator, argv.items, environment);
}

//
// Runs the TypeScript CLI with the arguments.
//
fn runTs(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "bun", (try clis(allocator)).ts });
    try argv.appendSlice(allocator, args);
    return helpers.runCli(allocator, argv.items, environment) catch |err| {

        // Comparing with the TypeScript CLI needs Bun; skip the test where Bun cannot be spawned.
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        }
        return err;
    };
}

//
// Expects both CLIs to exit with the same code and write the same output.
//
fn expectSameResult(tsResult: helpers.CliResult, zigResult: helpers.CliResult) !void {
    try std.testing.expectEqualStrings(tsResult.stdout, zigResult.stdout);
    try std.testing.expectEqualStrings(tsResult.stderr, zigResult.stderr);
    try std.testing.expectEqual(tsResult.exitCode, zigResult.exitCode);
}

//
// Creates a test root with two copies of test/dbs/v6.
//
fn setup(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const root = try helpers.makeTempDir(allocator, name);
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root}));
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root}));
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

test "verify prints the same report as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-verify");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});

    const tsResult = try normalize(allocator, try runTs(allocator, environment, &.{ "verify", "--db", dbTs, "--yes" }), dbTs, "<db>");
    const zigResult = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", dbZig, "--yes" }), dbZig, "<db>");
    try expectSameResult(tsResult, zigResult);
    try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, zigResult.stdout, "Database verification passed") != null);

    const tsFull = try normalize(allocator, try runTs(allocator, environment, &.{ "ver", "--db", dbTs, "--yes", "--full", "--path", "asset" }), dbTs, "<db>");
    const zigFull = try normalize(allocator, try runZig(allocator, environment, &.{ "ver", "--db", dbZig, "--yes", "--full", "--path", "asset" }), dbZig, "<db>");
    try expectSameResult(tsFull, zigFull);
}

test "verify reports a modified file like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-verify-modified");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});
    for ([_][]const u8{ dbTs, dbZig }) |db| {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/thumb", .{db}), .{ .iterate = true });
        defer dir.close(std.testing.io);
        var iterator = dir.iterate();
        const entry = (try iterator.next(std.testing.io)).?;
        try dir.writeFile(std.testing.io, .{ .sub_path = entry.name, .data = "changed" });
    }
    var tsResult = try normalize(allocator, try runTs(allocator, environment, &.{ "verify", "--db", dbTs, "--yes", "--full" }), dbTs, "<db>");
    var zigResult = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", dbZig, "--yes", "--full" }), dbZig, "<db>");

    // A verification that found problems exits with 1, which retains the session's temporary files.
    try std.testing.expectEqual(@as(u8, 1), zigResult.exitCode);
    tsResult.stdout = try maskRetainedSessionDir(allocator, tsResult.stdout);
    zigResult.stdout = try maskRetainedSessionDir(allocator, zigResult.stdout);
    try expectSameResult(tsResult, zigResult);
    try std.testing.expect(std.mem.indexOf(u8, zigResult.stdout, "Modified files:") != null);
}

test "verify reports a missing database like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-verify-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{root});
    const tsResult = try runTs(allocator, environment, &.{ "verify", "--db", missing, "--yes" });
    const zigResult = try runZig(allocator, environment, &.{ "verify", "--db", missing, "--yes" });
    // The session directory in the "Temporary files retained" line is random.
    try std.testing.expectEqual(tsResult.exitCode, zigResult.exitCode);
    const tsFirst = tsResult.stdout[0..std.mem.indexOf(u8, tsResult.stdout, "Temporary files").?];
    const zigFirst = zigResult.stdout[0..std.mem.indexOf(u8, zigResult.stdout, "Temporary files").?];
    try std.testing.expectEqualStrings(tsFirst, zigFirst);
}

test "replicate prints the same report as TypeScript and writes the same replica" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});
    const destTs = try std.fmt.allocPrint(allocator, "{s}/dest-ts", .{root});
    const destZig = try std.fmt.allocPrint(allocator, "{s}/dest-zig", .{root});

    const tsResult = try normalize(allocator, try normalize(allocator, try runTs(allocator, environment, &.{ "replicate", "--db", dbTs, "--dest", destTs, "--yes" }), destTs, "<dest>"), dbTs, "<db>");
    const zigResult = try normalize(allocator, try normalize(allocator, try runZig(allocator, environment, &.{ "replicate", "--db", dbZig, "--dest", destZig, "--yes" }), destZig, "<dest>"), dbZig, "<db>");
    try expectSameResult(tsResult, zigResult);
    try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);

    const assetId = "89171cd9-a652-4047-b869-1154bf2c95a1";
    const tsAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ destTs, assetId }), allocator, .unlimited);
    const zigAsset = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ destZig, assetId }), allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, tsAsset, zigAsset);

    // Replicating again to an existing destination with --yes updates it.
    const tsAgain = try normalize(allocator, try normalize(allocator, try runTs(allocator, environment, &.{ "rep", "--db", dbTs, "--dest", destTs, "--yes", "--partial" }), destTs, "<dest>"), dbTs, "<db>");
    const zigAgain = try normalize(allocator, try normalize(allocator, try runZig(allocator, environment, &.{ "rep", "--db", dbZig, "--dest", destZig, "--yes", "--partial" }), destZig, "<dest>"), dbZig, "<db>");
    try expectSameResult(tsAgain, zigAgain);
}

test "replicate rejects --partial with --full like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate-flags");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});
    const zigResult = try runZig(allocator, environment, &.{ "replicate", "--db", dbZig, "--dest", "/tmp/x", "--partial", "--full", "--yes" });
    const tsResult = try runTs(allocator, environment, &.{ "replicate", "--db", dbZig, "--dest", "/tmp/x", "--partial", "--full", "--yes" });
    try std.testing.expectEqual(tsResult.exitCode, zigResult.exitCode);
    try std.testing.expectEqualStrings(tsResult.stderr[0..std.mem.indexOf(u8, tsResult.stderr, "\n").?], zigResult.stderr[0..std.mem.indexOf(u8, zigResult.stderr, "\n").?]);
}

test "replicate rejects a key for an unencrypted destination like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-replicate-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});
    // The destination is the other (unencrypted) database.
    const tsResult = try runTs(allocator, environment, &.{ "replicate", "--db", dbTs, "--dest", dbZig, "--dest-key", "k", "--yes" });
    const zigResult = try runZig(allocator, environment, &.{ "replicate", "--db", dbZig, "--dest", dbTs, "--dest-key", "k", "--yes" });
    try std.testing.expectEqual(tsResult.exitCode, zigResult.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, zigResult.stderr, "You specified an encryption key, but the destination database is not encrypted.") != null);
    try std.testing.expect(std.mem.indexOf(u8, tsResult.stderr, "You specified an encryption key, but the destination database is not encrypted.") != null);
}

//
// Runs the Zig CLI with the arguments, its stdout written to a file.
//
fn runZigToFile(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, outputPath: []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, (try clis(allocator)).zig);
    try argv.appendSlice(allocator, args);
    return helpers.runCliToFile(allocator, argv.items, environment, outputPath);
}

//
// Runs the TypeScript CLI with the arguments, its stdout written to a file.
//
fn runTsToFile(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, outputPath: []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "bun", (try clis(allocator)).ts });
    try argv.appendSlice(allocator, args);
    return helpers.runCliToFile(allocator, argv.items, environment, outputPath) catch |err| {

        // Comparing with the TypeScript CLI needs Bun; skip the test where Bun cannot be spawned.
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "version prints the same report as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const tsResult = try runTs(allocator, environment, &.{"version"});
    const zigResult = try runZig(allocator, environment, &.{"version"});
    try expectSameResult(tsResult, zigResult);
    try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, zigResult.stdout, "Database version: 6") != null);

    const tsQuiet = try runTs(allocator, environment, &.{ "-q", "version" });
    const zigQuiet = try runZig(allocator, environment, &.{ "-q", "version" });
    try expectSameResult(tsQuiet, zigQuiet);
}

test "version written to a file is the same as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version-file");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    const tsResult = try runTsToFile(allocator, environment, &.{"version"}, try std.fmt.allocPrint(allocator, "{s}/ts.txt", .{root}));
    const zigResult = try runZigToFile(allocator, environment, &.{"version"}, try std.fmt.allocPrint(allocator, "{s}/zig.txt", .{root}));
    try expectSameResult(tsResult, zigResult);
}

test "--version prints the version like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-version-option");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    for ([_][]const []const u8{ &.{"--version"}, &.{ "ver", "--version" }, &.{ "version", "--version" } }) |args| {
        const tsResult = try runTs(allocator, environment, args);
        const zigResult = try runZig(allocator, environment, args);
        try expectSameResult(tsResult, zigResult);
        try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);
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
// Expects two databases to hold the same files with the same bytes, except the merkle tree of the files,
// which records the modification time of README.md; its database id is compared instead.
//
fn expectSameDatabase(allocator: std.mem.Allocator, tsDir: []const u8, zigDir: []const u8) !void {
    const relativePaths = [_][]const u8{
        "README.md",
        ".db/config.json",
        ".db/bson/indexes/metadata/hash_asc/tree.dat",
        ".db/bson/indexes/metadata/photoDate_desc/tree.dat",
    };
    for (relativePaths) |relativePath| {
        errdefer std.debug.print("file={s}\n", .{relativePath});
        const tsBytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ tsDir, relativePath }), allocator, .unlimited);
        const zigBytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(allocator, &.{ zigDir, relativePath }), allocator, .unlimited);
        try std.testing.expectEqualSlices(u8, tsBytes, zigBytes);
    }
    const tsStorage = try storage_zig.storage_factory.createStorage(allocator, std.testing.io, tsDir, null, null);
    const zigStorage = try storage_zig.storage_factory.createStorage(allocator, std.testing.io, zigDir, null, null);
    const tsTree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, std.testing.io, ".db/files.dat", tsStorage.storage, "FTRE")).?;
    const zigTree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, std.testing.io, ".db/files.dat", zigStorage.storage, "FTRE")).?;
    try std.testing.expectEqualStrings(tsTree.id, zigTree.id);
}

test "init prints the same report as TypeScript and creates the same database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});
    const tsEnvironment = try deterministicEnvironment(allocator, environment, try std.fmt.allocPrint(allocator, "{s}/ids-ts", .{root}));
    const zigEnvironment = try deterministicEnvironment(allocator, environment, try std.fmt.allocPrint(allocator, "{s}/ids-zig", .{root}));

    const tsResult = try normalize(allocator, try runTs(allocator, tsEnvironment, &.{ "init", "--db", dbTs, "--yes" }), dbTs, "<db>");
    const zigResult = try normalize(allocator, try runZig(allocator, zigEnvironment, &.{ "init", "--db", dbZig, "--yes" }), dbZig, "<db>");
    try expectSameResult(tsResult, zigResult);
    try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);
    try expectSameDatabase(allocator, dbTs, dbZig);

    // A database with the identity of another database.
    const relatedTs = try std.fmt.allocPrint(allocator, "{s}/related-ts", .{root});
    const relatedZig = try std.fmt.allocPrint(allocator, "{s}/related-zig", .{root});
    const databaseId = "3f2504e0-4f89-11d3-9a0c-0305e82c3301";
    const tsRelated = try normalize(allocator, try runTs(allocator, tsEnvironment, &.{ "i", "--db", relatedTs, "--database-id", databaseId, "-y" }), relatedTs, "<db>");
    const zigRelated = try normalize(allocator, try runZig(allocator, zigEnvironment, &.{ "i", "--db", relatedZig, "--database-id", databaseId, "-y" }), relatedZig, "<db>");
    try expectSameResult(tsRelated, zigRelated);
    try expectSameDatabase(allocator, relatedTs, relatedZig);
}

test "init refuses a directory that is not empty like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cmd-init-not-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});

    var tsResult = try normalize(allocator, try runTs(allocator, environment, &.{ "init", "--db", dbTs, "--yes" }), dbTs, "<db>");
    var zigResult = try normalize(allocator, try runZig(allocator, environment, &.{ "init", "--db", dbZig, "--yes" }), dbZig, "<db>");
    tsResult.stdout = try maskRetainedSessionDir(allocator, tsResult.stdout);
    zigResult.stdout = try maskRetainedSessionDir(allocator, zigResult.stdout);
    try expectSameResult(tsResult, zigResult);
    try std.testing.expectEqual(@as(u8, 1), zigResult.exitCode);
}

test "init rejects a malformed --database-id like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init-database-id");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});

    const tsResult = try runTs(allocator, environment, &.{ "init", "--db", dbTs, "--database-id", "not-a-uuid", "--yes" });
    const zigResult = try runZig(allocator, environment, &.{ "init", "--db", dbZig, "--database-id", "not-a-uuid", "--yes" });
    try std.testing.expectEqual(tsResult.exitCode, zigResult.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, zigResult.stderr, "\"not-a-uuid\" is not a database id.") != null);
}

test "init creates an encrypted database with a generated key like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-init-encrypted");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const dbTs = try std.fmt.allocPrint(allocator, "{s}/db-ts", .{root});
    const dbZig = try std.fmt.allocPrint(allocator, "{s}/db-zig", .{root});

    const tsResult = try normalize(allocator, try runTs(allocator, environment, &.{ "init", "--db", dbTs, "--key", "ts-key", "--generate-key", "--yes" }), dbTs, "<db>");
    const zigResult = try normalize(allocator, try runZig(allocator, environment, &.{ "init", "--db", dbZig, "--key", "zig-key", "--generate-key", "--yes" }), dbZig, "<db>");
    try std.testing.expectEqualStrings(tsResult.stdout, try std.mem.replaceOwned(u8, allocator, zigResult.stdout, "zig-key", "ts-key"));
    try std.testing.expectEqualStrings(tsResult.stderr, zigResult.stderr);
    try std.testing.expectEqual(@as(u8, 0), zigResult.exitCode);

    // Each CLI opens the database the other created with its key.
    const tsVerify = try runTs(allocator, environment, &.{ "verify", "--db", dbZig, "--key", "zig-key", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), tsVerify.exitCode);
    const zigVerify = try runZig(allocator, environment, &.{ "verify", "--db", dbTs, "--key", "ts-key", "--yes" });
    try std.testing.expectEqual(@as(u8, 0), zigVerify.exitCode);
}
