const std = @import("std");
const helpers = @import("test-helpers.zig");

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
