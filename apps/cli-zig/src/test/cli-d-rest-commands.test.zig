//
// The failure paths and the edge cases of the list, compare, export, hash-cache, news, summary and root-hash
// commands that the other test files leave out (apps/cli-zig/src/cmd/list.zig, compare.zig, hash-cache.zig,
// summary.zig and news.zig against apps/cli/src/cmd/list.ts, compare.ts, hash-cache.ts, summary.ts and news.ts).
//
// The reports the tests expect are written out here from the TypeScript CLI: the "No files found in the database."
// of listCommand (apps/cli/src/cmd/list.ts), the "... and N more" truncation of compareCommand
// (apps/cli/src/cmd/compare.ts), the "No database found" of loadDatabase (apps/cli/src/lib/init-cmd.ts), the
// "Local Hash Cache" report of hashCacheCommand (apps/cli/src/cmd/hash-cache.ts), the "No news items available."
// of newsCommand (apps/cli/src/cmd/news.ts) and the summary report of summaryCommand
// (apps/cli/src/cmd/summary.ts).
//

const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("test-helpers.zig");
const cli = @import("cli-zig");

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
// Fails the test with what the CLI wrote when it did not do what the test expects, so that a failure says what
// it actually printed rather than nothing at all.
//
fn expectWhat(result: helpers.CliResult, condition: bool, allocator: std.mem.Allocator, message: []const u8) !void {
    if (condition) {
        return;
    }
    std.debug.print("{s} (exit code {d})\nstdout:\n{s}\nstderr:\n{s}\n", .{ message, result.exitCode, result.stdout, result.stderr });
    _ = allocator;
    return error.TestExpectedEqual;
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
        .stdout = try std.mem.replaceOwned(u8, allocator, result.stdout, path, placeholder),
        .stderr = try std.mem.replaceOwned(u8, allocator, result.stderr, path, placeholder),
    };
}

//
// The environment of a test that lets a command keep its hash cache inside the test root, so that a test never
// reads or writes the hash cache of another test, or of the machine it runs on.
//
fn isolatedCacheEnvironment(allocator: std.mem.Allocator, root: []const u8) !*std.process.Environ.Map {
    const environment = try helpers.cliEnvironment(allocator, root);
    try environment.put("PHOTOSPHERE_CACHE_DIR", try std.fs.path.join(allocator, &.{ root, "cache" }));
    return environment;
}

//
// Creates a test root with a copy of one of the databases of test/dbs in <root>/<name>.
//
fn setupDatabase(allocator: std.mem.Allocator, name: []const u8, fixture: []const u8) ![]const u8 {
    const root = try helpers.makeTempDir(allocator, name);
    try helpers.copyDirectory(allocator, try std.fs.path.join(allocator, &.{ "../../test/dbs", fixture }), try std.fs.path.join(allocator, &.{ root, "db" }));
    return root;
}

//
// Counts how many times a line appears in the text (the number of records a listing printed).
//
fn countLines(text: []const u8, line: []const u8) usize {
    var count: usize = 0;
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, text, position, line)) |found| {
        count += 1;
        position = found + line.len;
    }
    return count;
}

//
// The report of listCommand (apps/cli/src/cmd/list.ts) for a database whose sort index holds no records: nothing
// has been displayed, so it says so rather than printing the end-of-results line.
//
const list_empty_report =
    \\
    \\📁 Database Files
    \\
    \\Files are sorted by date (newest first).
    \\
    \\No files found in the database.
    \\
;

//
// The report of summaryCommand (apps/cli/src/cmd/summary.ts) for test/dbs/no-assets: the database holds the
// README.md and its tree, and no asset, so nothing has been imported. It has no database hash, because a
// database with no asset has no asset tree hash of its own, which is the branch the report only prints the
// files hash for.
//
const summary_empty_report_tail =
    \\Files imported:   0
    \\Total files:      1
    \\Total size:       913 Bytes
    \\Database version: 6
    \\Files hash:       94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7
    \\Full root hash:   94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7
    \\
;

test "list and summary report a database with no assets like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupDatabase(allocator, "cmd-d-list-empty", "no-assets");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try isolatedCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--yes" }), list_empty_report, "", 0);

    // A page size of any size shows the same empty database.
    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--page-size", "1", "--yes" }), list_empty_report, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "list", "--db", db, "--page-size=-1", "--yes" }), list_empty_report, "", 0);

    const summary = try runZig(allocator, environment, &.{ "summary", "--db", db, "--yes" });
    try std.testing.expect(std.mem.indexOf(u8, summary.stdout, summary_empty_report_tail) != null);
    try std.testing.expectEqual(@as(u8, 0), summary.exitCode);
    // A database with no asset has no database hash, so that line of the report is absent.
    try std.testing.expect(std.mem.indexOf(u8, summary.stdout, "Database hash:") == null);
}

test "list counts back from the end of the page for a negative page size like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupDatabase(allocator, "cmd-d-list-negative", "50-assets");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try isolatedCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    // test/dbs/50-assets holds 50 records and its sort index holds them in one page, so the page is every
    // record there is. `records.slice(0, -1)` drops the last one, which is 49 records, where the page size
    // that is not a number (NaN) and a page size of 0 both drop all of them.
    const negative = try runZig(allocator, environment, &.{ "list", "--db", db, "--page-size=-1", "--yes" });
    try expectWhat(negative, countLines(negative.stdout, "  Encryption: unencrypted\n") == 49, allocator, "a negative page size did not drop the last record of the page");
    try expectWhat(negative, std.mem.endsWith(u8, negative.stdout, "\nEnd of results. Displayed 49 files total.\n"), allocator, "the count of the records the negative page size showed is not 49");
    try std.testing.expectEqualStrings("", negative.stderr);
    try std.testing.expectEqual(@as(u8, 0), negative.exitCode);

    // A page size of 0 shows the header of the page and no records at all.
    const zero = try runZig(allocator, environment, &.{ "list", "--db", db, "--page-size", "0", "--yes" });
    try expectWhat(zero, countLines(zero.stdout, "  Encryption: unencrypted\n") == 0, allocator, "a page size of 0 showed a record");
    try expectWhat(zero, std.mem.endsWith(u8, zero.stdout, "--- Page 1 ---\n\nEnd of results. Displayed 0 files total.\n"), allocator, "a page size of 0 did not show an empty page");
}

//
// The report of compareCommand (apps/cli/src/cmd/compare.ts) for test/dbs/1-asset against test/dbs/1-asset-2 with
// --max that is not a number: `onlyInA.slice(0, NaN)` is empty and `length > NaN` is false, so the headings are
// printed with nothing under them and the "... and N more" line is not.
//
const compare_max_not_a_number_report =
    \\
    \\Comparing two databases:
    \\  Source:         <root>/source
    \\  Destination:    <root>/dest
    \\
    \\
    \\📊 Comparison Results
    \\
    \\Found differences: 3 files only in source, 3 files only in destination
    \\
    \\Files only in source:
    \\
    \\Files only in destination:
    \\
    \\⚠️ Databases have 6 differences
    \\
;

//
// The report of compareCommand (apps/cli/src/cmd/compare.ts) for test/dbs/1-asset against test/dbs/1-asset-2 with
// --max 0: nothing is listed, and every category says how many files it did not list, because `length > 0` and
// `length - 0` are what the TypeScript writes.
//
const compare_max_zero_report =
    \\
    \\Comparing two databases:
    \\  Source:         <root>/source
    \\  Destination:    <root>/dest
    \\
    \\
    \\📊 Comparison Results
    \\
    \\Found differences: 3 files only in source, 3 files only in destination
    \\
    \\Files only in source:
    \\  ... and 3 more
    \\
    \\Files only in destination:
    \\  ... and 3 more
    \\
    \\⚠️ Databases have 6 differences
    \\
;

//
// Rewrites the `/` of an expected report into the separator of the platform, because the paths in a report are
// joined with node-utils' path.join (the port of Node's path.join), which writes a `\` on Windows. Only the paths
// of these reports contain a `/`, so replacing every one of them changes nothing else.
//
fn withPlatformSeparators(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return std.mem.replaceOwned(u8, allocator, text, "/", "\\");
    }
    return text;
}

//
// The report of compareCommand (apps/cli/src/cmd/compare.ts) for test/dbs/1-asset against test/dbs/1-asset-2 with
// --full: every file of every category is listed and the "... and N more" line is not.
//
const compare_full_report_tail =
    \\
    \\Files only in source:
    \\  + asset/63e9c63a-9164-6376-13e9-ef4d00000000
    \\  + display/63e9c63a-9164-6376-13e9-ef4d00000000
    \\  + thumb/63e9c63a-9164-6376-13e9-ef4d00000000
    \\
    \\Files only in destination:
    \\  + asset/476dffbb-af9e-4cda-8006-b02f3851e86c
    \\  + display/476dffbb-af9e-4cda-8006-b02f3851e86c
    \\  + thumb/476dffbb-af9e-4cda-8006-b02f3851e86c
    \\
    \\⚠️ Databases have 6 differences
    \\
;

test "compare lists nothing for a maximum that is not a number and everything for --full, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-d-compare-max");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try isolatedCacheEnvironment(allocator, root);
    const source = try std.fs.path.join(allocator, &.{ root, "source" });
    const destination = try std.fs.path.join(allocator, &.{ root, "dest" });
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset", source);
    try helpers.copyDirectory(allocator, "../../test/dbs/1-asset-2", destination);

    const notANumber = try normalize(allocator, try runZig(allocator, environment, &.{ "compare", "--db", source, "--dest", destination, "--max", "abc", "--yes" }), root, "<root>");
    try expectResult(notANumber, try withPlatformSeparators(allocator, compare_max_not_a_number_report), "", 0);

    const full = try normalize(allocator, try runZig(allocator, environment, &.{ "compare", "--db", source, "--dest", destination, "--full", "--yes" }), root, "<root>");
    try expectWhat(full, std.mem.indexOf(u8, full.stdout, compare_full_report_tail) != null, allocator, "--full did not list every file of every category");
    try expectWhat(full, std.mem.indexOf(u8, full.stdout, "... and") == null, allocator, "--full truncated a category");
    try std.testing.expectEqualStrings("", full.stderr);
    try std.testing.expectEqual(@as(u8, 0), full.exitCode);

    // A maximum of 0 shows nothing, and every category says how many it did not show, because 0 is a number
    // that any number of files is more than (TypeScript: `length > 0`, `length - 0`).
    const zeroMax = try normalize(allocator, try runZig(allocator, environment, &.{ "compare", "--db", source, "--dest", destination, "--max", "0", "--yes" }), root, "<root>");
    try expectResult(zeroMax, try withPlatformSeparators(allocator, compare_max_zero_report), "", 0);
}

//
// The report of loadDatabase (apps/cli/src/lib/init-cmd.ts) when the destination of compare is not a database.
//
const compare_missing_dest_report =
    \\
    \\✗ No database found at: <missing>
    \\  The database directory must contain a ".db" folder with files.dat or tree.dat.
    \\
    \\To create a new database at this directory, use:
    \\  psi init --db <missing>
    \\Temporary files retained for inspection: <session dir>
    \\
;

test "compare reports a destination that is not a database like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupDatabase(allocator, "cmd-d-compare-missing", "1-asset");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try isolatedCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });
    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });

    const result = try runZig(allocator, environment, &.{ "compare", "--db", db, "--dest", missing, "--yes" });
    var normalized = try normalize(allocator, result, missing, "<missing>");
    normalized.stdout = try maskRetainedSessionDir(allocator, normalized.stdout);
    try expectResult(normalized, compare_missing_dest_report, "", 1);

    // Nothing is compared, so the results are never printed.
    try std.testing.expect(std.mem.indexOf(u8, normalized.stdout, "Comparison Results") == null);
}

//
// The report of newsCommand (apps/cli/src/cmd/news.ts) when the feed holds no items.
//
const news_empty_report =
    \\
    \\📋 Photosphere News
    \\
    \\Running version: vdev
    \\
    \\No news items available.
    \\
;

test "news says the feed is empty like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cmd-d-news-empty");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    // cliEnvironment writes a feed with no items and points PHOTOSPHERE_NEWS_URL at it, so no network is used.
    const environment = try helpers.cliEnvironment(allocator, root);

    try expectResult(try runZig(allocator, environment, &.{"news"}), news_empty_report, "", 0);
    try expectResult(try runZig(allocator, environment, &.{ "-q", "news" }), news_empty_report, "", 0);
}

//
// The SHA-256 hash of test/test.png, which the hash cache report of the test below prints.
//
const test_png_hash = "3d9d6f073e60a13e6706bec322b47615f76b594b17bd64495614996b995908d9";

test "hash-cache show names the asset id of an entry added by add, like the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupDatabase(allocator, "cmd-d-hash-cache-asset-id", "no-assets");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try isolatedCacheEnvironment(allocator, root);
    const db = try std.fs.path.join(allocator, &.{ root, "db" });

    const added = try runZig(allocator, environment, &.{ "add", "../../test/test.png", "--db", db, "--yes" });
    try expectWhat(added, added.exitCode == 0, allocator, "adding a file to the database failed");

    const dirResult = try runZig(allocator, environment, &.{ "hash-cache", "dir", "--db", db });
    const location = dirResult.stdout[0 .. dirResult.stdout.len - 1];
    const shown = try runZig(allocator, environment, &.{ "hash-cache", "show", "--db", db, "--yes" });
    try expectWhat(shown, shown.exitCode == 0, allocator, "showing the hash cache failed");

    const expectedHead = try std.fmt.allocPrint(allocator,
        \\
        \\=== Local Hash Cache ===
        \\Database: {s}
        \\Location: {s}
        \\Entries: 1
        \\
        \\Cache entries:
        \\
        \\
    , .{ db, location });
    try expectWhat(shown, std.mem.startsWith(u8, shown.stdout, expectedHead), allocator, "the head of the hash cache report is not what it should be");

    // The entry is keyed by the path of the file add was given, and holds the hash add computed. The key is
    // written exactly as add recorded it (without its leading separator, as addFiles records it), so the test
    // matches the end of the path and the line under it rather than the whole path. The key keeps the forward
    // slashes of the path it was given, not the separator of the platform: add was given `../../test/test.png`,
    // and the key is that path resolved without changing its separators, so it ends in `test/test.png`
    // everywhere.
    const keySuffix = "test/test.png\n    Keyed by: file path\n";
    try expectWhat(shown, std.mem.indexOf(u8, shown.stdout, keySuffix) != null, allocator, "the hash cache entry is not keyed by the path add hashed");
    try expectWhat(shown, std.mem.indexOf(u8, shown.stdout, try std.fmt.allocPrint(allocator, "\n    Hash: {s}\n", .{test_png_hash})) != null, allocator, "the hash cache entry does not hold the hash of the file");

    // add records the id the new asset has in the database, where the entries the tools record do not have one,
    // and a single entry is counted in the singular.
    const assetIdStart = std.mem.indexOf(u8, shown.stdout, "    Asset id: ") orelse {
        return expectWhat(shown, false, allocator, "the hash cache report has no asset id line");
    };
    const assetIdEnd = std.mem.indexOfScalarPos(u8, shown.stdout, assetIdStart, '\n').?;
    const assetId = shown.stdout[assetIdStart + "    Asset id: ".len .. assetIdEnd];
    try expectWhat(shown, assetId.len == 36 and std.mem.eql(u8, "-", assetId[8..9]), allocator, "the asset id of the entry is not a uuid");
    try expectWhat(shown, std.mem.indexOf(u8, shown.stdout, "  Total: 1 entry\n\n") != null, allocator, "a single entry was not counted in the singular");
}