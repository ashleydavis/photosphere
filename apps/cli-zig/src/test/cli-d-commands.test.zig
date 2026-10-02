//
// The failure paths of the replicate, sync, verify and add commands (apps/cli-zig/src/cmd/replicate.zig,
// sync.zig, verify.zig and add.zig against apps/cli/src/cmd/replicate.ts, sync.ts, verify.ts and add.ts).
//
// The reports the tests expect are written out here from the TypeScript CLI: the "✗ Path does not exist" of
// addCommand (apps/cli/src/cmd/add.ts), the "No database found" of loadDatabase (apps/cli/src/lib/init-cmd.ts),
// the "✗ Encryption key ... not found" of replicateCommand and syncCommand, the "Removed files:" and
// "Invalid database files:" sections of verifyCommand (apps/cli/src/cmd/verify.ts) and the "Source files deleted: "
// line addCommand writes under --cleanup, which has no count behind it in the TypeScript either.
//

const std = @import("std");
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
// Runs the Zig CLI with the arguments, writing the input to its stdin and then closing it, as
// `printf '...' | psi ...` does. The input is what a person typing the keys would send.
//
fn runZigWithInput(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, input: []const u8) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigCliPath(allocator));
    try argv.appendSlice(allocator, args);
    return helpers.runCliWithInput(allocator, argv.items, input, environment);
}

//
// Runs the Zig CLI with the arguments, typing the keys of each prompt on its stdin once that prompt has
// appeared on its stdout. A person answers one prompt at a time, and a prompt drops the rest of what it
// reads when it finishes, so the keys of the second prompt cannot be written with those of the first.
//
fn runZigWithPrompts(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, args: []const []const u8, prompts: []const helpers.IPromptKeys) !helpers.CliResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, try zigCliPath(allocator));
    try argv.appendSlice(allocator, args);
    return helpers.runWithPrompts(allocator, argv.items, prompts, environment);
}

//
// Expects the count of copied files the report of replicateCommand writes, printing the report when it is a
// different count.
//
fn expectFilesCopied(stdout: []const u8, expected: []const u8) !void {
    const copied = filesCopiedLine(stdout);
    if (!std.mem.eql(u8, copied, expected)) {
        std.debug.print("expected {s} files copied, the report says {s}, in:\n{s}\n", .{ expected, copied, stdout });
        return error.TestExpectedEqual;
    }
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
// True when there is a file at the path (what a command under test did or did not do to the disk).
//
fn fileExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.testing.io, path, .{}) catch {
        return false;
    };
    return true;
}

//
// Creates a test root with a copy of test/dbs/v6 in <root>/db, the name of the asset of that database.
//
fn setup(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const root = try helpers.makeTempDir(allocator, name);
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", try std.fmt.allocPrint(allocator, "{s}/db", .{root}));
    return root;
}

//
// The one asset of test/dbs/v6, whose files are the asset, display and thumb file of that id.
//
const asset_id = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// The keys of a prompt: the down arrow and enter (pick the second option of a select prompt).
//
const down_and_enter = "\x1b[B\r";

//
// The keys of a prompt: enter (submit whatever is selected, which is the first option of a select prompt and the
// initial value of a confirm prompt).
//
const enter = "\r";

//
// The keys of a prompt: y (answer yes to a confirm prompt).
//
const yes = "y";

//
// The keys of a prompt: n (answer no to a confirm prompt).
//
const no = "n";

//
// The number of files each mode of replicate copied, read from the "Total files copied" line of the report of
// replicateCommand (apps/cli/src/cmd/replicate.ts), for a destination whose one asset was removed before the run:
// a full replication copies the asset, display and thumb file back (3), a partial one copies no file and
// fetches the asset and display files from the origin on demand instead (0).
//
fn filesCopiedLine(stdout: []const u8) []const u8 {
    const label = "Total files copied:        ";
    const start = std.mem.indexOf(u8, stdout, label) orelse {
        return "no line";
    };
    const end = std.mem.indexOfScalarPos(u8, stdout, start, '\n') orelse stdout.len;
    return stdout[start + label.len .. end];
}

//
// Expects there to be a file at the path, printing the files of its directory when there is not (a run that copied
// the files of a database and one that did not leave the same directory behind).
//
fn expectFileExists(path: []const u8) !void {
    if (fileExists(path)) {
        return;
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    var directory = std.Io.Dir.cwd().openDir(std.testing.io, std.fs.path.dirname(path).?, .{ .iterate = true }) catch |err| {
        std.debug.print("expected the file {s} to exist, and its directory could not be read: {t}\n", .{ path, err });
        return error.TestUnexpectedResult;
    };
    defer directory.close(std.testing.io);
    var walker = try directory.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        try names.append(std.testing.allocator, entry.path);
    }
    std.debug.print("expected the file {s} to exist, its directory holds:\n", .{path});
    for (names.items) |name| {
        std.debug.print("  {s}\n", .{name});
    }
    return error.TestUnexpectedResult;
}

//
// Expects the text to hold the needle. An expect that reports nothing but the fact that it failed says nothing
// about which of the thirty lines of a report it was looking at, so this one prints the text it was given.
//
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

//
// Expects the text not to hold the needle, printing the text when it does.
//
fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected not to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

//
// Expects the text to start with the prefix, printing the text when it does not.
//
fn expectStartsWith(haystack: []const u8, prefix: []const u8) !void {
    if (!std.mem.startsWith(u8, haystack, prefix)) {
        std.debug.print("expected to start with:\n{s}\nin:\n{s}\n", .{ prefix, haystack });
        return error.TestExpectedEqual;
    }
}

//
// The prompt the mode select is: replicateCommand (apps/cli/src/cmd/replicate.ts) asks which mode to use when
// neither --partial nor --full was given and --yes was not either.
//
const mode_prompt_text = "How would you like to replicate the database?";

//
// The prompt the overwrite of an existing destination is asked at.
//
const overwrite_prompt_text = "Do you want to proceed with replication?";

//
// The mode select and the overwrite confirmation, answered with the keys each prompt is given.
//
fn replicatePrompts(modeKeys: []const u8, confirmKeys: []const u8) [2]helpers.IPromptKeys {
    return .{
        .{
            .waitFor = mode_prompt_text,
            .keys = modeKeys,
        },
        .{
            .waitFor = overwrite_prompt_text,
            .keys = confirmKeys,
        },
    };
}

//
// The overwrite confirmation alone, answered with the keys it is given.
//
fn overwritePrompt(confirmKeys: []const u8) [1]helpers.IPromptKeys {
    return .{
        .{
            .waitFor = overwrite_prompt_text,
            .keys = confirmKeys,
        },
    };
}

//
// The report replicateCommand prints for a full replication of the asset removed from the destination, and the
// files the destination holds afterwards, proving that the full mode was the one that ran.
//
test "replicate copies the files back when the full mode is chosen at the prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-replicate-full");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    try expectResult(try runZig(allocator, environment, &.{ "remove", "--db", dest, asset_id, "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Successfully removed asset {s} from database\n", .{asset_id}), "", 0);

    const result = try runZigWithPrompts(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest }, &replicatePrompts(enter, yes));

    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try expectFilesCopied(result.stdout, "3");
    try expectContains(result.stdout, "Total records copied:      1");
    try expectContains(result.stdout, "\u{2705} Replication completed successfully");
    // The full mode copied the asset file back, which the partial mode leaves for the origin to serve.
    try expectFileExists(try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dest, asset_id }));
}

//
// The same run answering the mode select with the down arrow and enter, which is the partial mode: the report
// copies no file and the destination is left without the asset, display and thumb files. This is the branch
// replicateCommand reads the mode out of the select result for (apps/cli-zig/src/cmd/replicate.zig).
//
test "replicate leaves the files for the origin when the partial mode is chosen at the prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-replicate-partial");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    _ = try runZig(allocator, environment, &.{ "remove", "--db", dest, asset_id, "--yes" });

    const result = try runZigWithPrompts(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest }, &replicatePrompts(down_and_enter, yes));

    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try expectFilesCopied(result.stdout, "0");
    try std.testing.expect(!fileExists(try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dest, asset_id })));
}

//
// The confirmation before an existing destination is overwritten, answered no: replicateCommand writes
// "Replication cancelled." and ends without copying anything (apps/cli/src/cmd/replicate.zig).
//
test "replicate asks before overwriting a destination and cancels when the answer is no" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-replicate-no");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    try expectResult(try runZig(allocator, environment, &.{ "remove", "--db", dest, asset_id, "--yes" }), try std.fmt.allocPrint(allocator, "\u{2713} Successfully removed asset {s} from database\n", .{asset_id}), "", 0);
    const destHashBefore = try runZig(allocator, environment, &.{ "root-hash", "--db", dest, "--yes" });

    const result = try runZigWithPrompts(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest, "--full" }, &overwritePrompt(no));

    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    // The two warnings of the overwrite are the only thing on stderr, and they name the destination.
    try expectContains(result.stderr, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  The destination database already exists at {s}.\n    Replication will overwrite any changes made to the destination database.\n", .{dest}));
    try expectContains(result.stdout, "Replication cancelled.");
    try expectNotContains(result.stdout, "Replication completed successfully");
    try std.testing.expect(!fileExists(try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dest, asset_id })));
    const destHashAfter = try runZig(allocator, environment, &.{ "root-hash", "--db", dest, "--yes" });
    try std.testing.expectEqualStrings(destHashBefore.stdout, destHashAfter.stdout);
}

//
// The same confirmation answered yes: the replication runs, which is the branch where the confirm result is a
// submitted value rather than a cancel and rather than a no.
//
test "replicate overwrites the destination when the confirmation is answered yes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-replicate-yes");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    _ = try runZig(allocator, environment, &.{ "remove", "--db", dest, asset_id, "--yes" });

    const result = try runZigWithPrompts(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest, "--full" }, &overwritePrompt(yes));

    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try expectNotContains(result.stdout, "Replication cancelled.");
    try expectContains(result.stdout, "\u{2705} Replication completed successfully");
    try expectFilesCopied(result.stdout, "3");
    try expectFileExists(try std.fmt.allocPrint(allocator, "{s}/asset/{s}", .{ dest, asset_id }));
}

//
// What replicateCommand prints when the destination is an encrypted database and the key it was given is not in
// the vault (apps/cli/src/cmd/replicate.ts: the resolveKeyPemsWithPrompt of the existing destination).
//
const replicate_missing_key_error =
    \\✗ Encryption key "nosuchkey" not found. Use "psi secrets list" to see available keys.
    \\
;

//
// The "Did you mean" list is empty here because the vault holds no key at all, which findSimilarKeyNames reads.
//
test "replicate refuses an encrypted destination whose key is not in the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-replicate-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    // The encryption marker is what says a database is encrypted.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{dest}), .data = "a public key\n" });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "replicate", "--db", db, "--dest", dest, "--dest-key", "nosuchkey", "--yes" }), root, "<root>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(replicate_missing_key_error, result.stderr);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "\nErrors, warnings, and exceptions were logged to: "));
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
}

//
// What syncCommand prints when the destination is an encrypted database and the key it was given is not in the
// vault (apps/cli/src/cmd/sync.ts: the resolveKeyPemsWithPrompt of the existing destination).
//
test "sync refuses an encrypted destination whose key is not in the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-sync-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const dest = try std.fmt.allocPrint(allocator, "{s}/dest", .{root});
    try helpers.copyDirectory(allocator, "../../test/dbs/v6", dest);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{dest}), .data = "a public key\n" });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "sync", "--db", db, "--dest", dest, "--dest-key", "nosuchkey", "--yes" }), root, "<root>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try expectStartsWith(result.stdout,
        \\Starting database sync operation...
        \\  Source:    <root>/db
        \\  Target:    <root>/dest
        \\
        \\
    );
    try std.testing.expectEqualStrings(replicate_missing_key_error, result.stderr);
}

//
// configOrigin (apps/cli-zig/src/cmd/sync.zig) reads `config?.origin` the way syncCommand
// (apps/cli/src/cmd/sync.ts) does: a missing config, a config that is not an object, an object with no origin and
// an origin that is not a string all give no destination, and only a string gives one.
//
test "configOrigin reads a string origin and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(cli.sync.configOrigin(null) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "42", .{})) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "\"origin\"", .{})) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{}", .{})) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"origin\":42}", .{})) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"origin\":null}", .{})) == null);
    try std.testing.expect(cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"mode\":\"full\",\"origin\":\"/photos/backup\"}", .{})) != null);
    try std.testing.expectEqualStrings("/photos/backup", cli.sync.configOrigin(try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"mode\":\"full\",\"origin\":\"/photos/backup\"}", .{})).?);
}

//
// What verifyCommand prints for test/dbs/v6 with its thumb file deleted: the file is in the tree of the database
// and no longer on disk, so it is reported as removed and the command ends non-zero.
//
const verify_removed_report_tail =
    \\Removed:           1
    \\Failures:          0
    \\Record mismatches: 0
    \\
    \\Removed files:
    \\  - thumb/
;

//
// verifyFoundProblems (apps/cli-zig/src/cmd/verify.zig) counts a removed file as a problem, which is what makes
// the exit code 1.
//
test "verify reports a file that is in the database but no longer on disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-verify-removed");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const thumbPath = try std.fmt.allocPrint(allocator, "{s}/thumb/{s}", .{ db, asset_id });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, thumbPath);

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--yes", "--full" }), db, "<db>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try expectContains(result.stdout, verify_removed_report_tail);
    try expectContains(result.stdout, try std.fmt.allocPrint(allocator, "  - thumb/{s}", .{asset_id}));
    try expectContains(result.stdout, "\u{26A0}\u{FE0F} Asset file verification found issues - see details above");
    // A database with a problem is told to repair itself, not to back itself up.
    try expectContains(result.stdout, "psi repair --source <backup-db-path>");
    try expectNotContains(result.stdout, "psi replicate --db <db> --dest <other-db-path>");
}

//
// The shard of test/dbs/v6 written over with seven bytes, which the v6 format cannot read, so verifyDatabaseFiles
// reports it as an invalid database file and verifyCommand ends non-zero.
//
const verify_invalid_database_file_report_tail =
    \\Database files:
    \\  Total files:    8
    \\  Total size:     354 KiB
    \\  Valid files:    7
    \\  Invalid files:  1
    \\
    \\Invalid database files:
    \\  ● .db/bson/collections/metadata/shards/96.dat
    \\    File too small for v6 format (7 bytes, minimum 40)
    \\
    \\❌ Database file verification failed - 1 file(s) have issues
    \\
;

//
test "verify reports a database file it cannot read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-verify-corrupt");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/bson/collections/metadata/shards/96.dat", .{db}),
        .data = "corrupt",
    });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", db, "--yes" }), db, "<db>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try expectContains(result.stdout, verify_invalid_database_file_report_tail);
    try expectContains(result.stdout, "psi repair --source <backup-db-path>");
}

//
// What loadDatabase (apps/cli/src/lib/init-cmd.ts) prints for a path that is a file rather than a database
// directory: there is no .db folder in it, so there is no database there either.
//
const verify_plain_file_report =
    \\
    \\✗ No database found at: <plain>
    \\  The database directory must contain a ".db" folder with files.dat or tree.dat.
    \\
    \\To create a new database at this directory, use:
    \\  psi init --db <plain>
    \\Temporary files retained for inspection: <session dir>
    \\
;

//
test "verify reports a path that is a file rather than a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "cli-d-verify-plain");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const plain = try std.fmt.allocPrint(allocator, "{s}/plain.txt", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = plain, .data = "not a database\n" });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "verify", "--db", plain, "--yes" }), plain, "<plain>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try expectResult(result, verify_plain_file_report, "", 1);
}

//
// What addCommand prints for a path that is not there (apps/cli/src/cmd/add.ts checks every path it was given
// before it loads the database, so nothing else is printed and nothing is imported).
//
const add_missing_path_error =
    \\
    \\✗ Path does not exist: <missing>
    \\  Please verify the path is correct and try again.
    \\
    \\
;

//
test "add refuses a path that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setup(allocator, "cli-d-add-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const missing = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "add", "--db", db, "--yes", missing }), missing, "<missing>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings(add_missing_path_error, result.stderr);
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, "-errors.log\nTemporary files retained for inspection: <session dir>\n"));
}

//
// The one file of the source folder addCommand is given under --cleanup, the asset file of test/dbs/v6, and the
// folder it sits in. It is a real JPEG, so importing it does what importing any photo does.
//
const source_photo_name = "photo.jpg";

//
// Puts a copy of the asset file of test/dbs/v6 in <root>/photos, as the folder addCommand is given.
//
fn writeSourcePhoto(allocator: std.mem.Allocator, root: []const u8) ![]const u8 {
    const photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, photosDir);
    const sourcePath = try std.fs.path.join(allocator, &.{ "../../test/dbs/v6/asset", asset_id });
    const photosDirHandle = try std.Io.Dir.cwd().openDir(std.testing.io, photosDir, .{});
    defer photosDirHandle.close(std.testing.io);
    try std.Io.Dir.cwd().copyFile(sourcePath, photosDirHandle, source_photo_name, std.testing.io, .{});
    return try std.fs.path.join(allocator, &.{ photosDir, source_photo_name });
}

//
// The summary addCommand prints after importing the one photo of <root>/photos into test/dbs/no-assets: the file
// is added, and the report says so.
//
const add_imported_summary =
    \\Added 1 files to the media database.
    \\
    \\Summary:
    \\Files considered: 1
    \\Files added:      1
    \\Files ignored:    0
    \\Files failed:     0
    \\Already added:    0
    \\
;

//
// Creates a test root with a copy of test/dbs/no-assets (a database with no asset in it) in <root>/db, and the
// photo to import in <root>/photos.
//
fn setupAdd(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const root = try helpers.makeTempDir(allocator, name);
    try helpers.copyDirectory(allocator, "../../test/dbs/no-assets", try std.fmt.allocPrint(allocator, "{s}/db", .{root}));
    _ = try writeSourcePhoto(allocator, root);
    return root;
}

//
// addCommand under --cleanup deletes the source files the database holds, which is what cleanUpImportedSources
// (apps/cli-zig/src/cmd/add.zig) does: the second run finds the photo already imported, deletes it from the disk
// and writes the count of what it deleted. The TypeScript writes that line with no count behind it, and this port
// mirrors that (see the TODO at apps/cli-zig/src/cmd/add.zig).
//
test "add deletes the source file the database already holds under --cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupAdd(allocator, "cli-d-add-cleanup");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});
    const photo = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ photosDir, source_photo_name });

    const firstRun = try normalize(allocator, try runZig(allocator, environment, &.{ "add", "--db", db, "--yes", photosDir }), root, "<root>");
    try std.testing.expectEqual(@as(u8, 0), firstRun.exitCode);
    try expectContains(firstRun.stdout, add_imported_summary);
    try expectFileExists(photo);

    const secondRun = try normalize(allocator, try runZig(allocator, environment, &.{ "add", "--db", db, "--yes", "--cleanup", photosDir }), root, "<root>");

    try std.testing.expectEqual(@as(u8, 0), secondRun.exitCode);
    try expectContains(secondRun.stdout, "Looking for source files the database already holds...");
    // The line the TypeScript writes with no count behind it, which this port mirrors.
    try expectContains(secondRun.stdout, "Source files deleted: \n");
    try expectContains(secondRun.stdout, "Files added:      0\nFiles ignored:    0\nFiles failed:     0\nAlready added:    1\n");
    // The source file is gone from the disk, which is what the run was for.
    try std.testing.expect(!fileExists(photo));
}

//
// The same run against a database that says it is encrypted while the key it was given is not in the vault, which
// is what a missing or emptied vault looks like: loadDatabase (apps/cli/src/lib/init-cmd.ts) stops addCommand
// before it imports anything, so the photo the run was given is left where it was.
//
const add_missing_key_report =
    \\
    \\✗ Encryption key "nosuchkey" not found.
    \\  Use "psi secrets list" to see available keys.
    \\Temporary files retained for inspection: <session dir>
    \\
;

//
test "add refuses a database whose key is not in the vault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try setupAdd(allocator, "cli-d-add-key");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);
    const db = try std.fmt.allocPrint(allocator, "{s}/db", .{root});
    const photosDir = try std.fmt.allocPrint(allocator, "{s}/photos", .{root});
    const photo = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ photosDir, source_photo_name });
    // The encryption marker is what says a database is encrypted.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = try std.fmt.allocPrint(allocator, "{s}/.db/encryption.pub", .{db}),
        .data = "a public key\n",
    });

    var result = try normalize(allocator, try runZig(allocator, environment, &.{ "add", "--db", db, "--key", "nosuchkey", "--yes", photosDir }), db, "<db>");
    result.stdout = try maskRetainedSessionDir(allocator, result.stdout);

    try expectResult(result, add_missing_key_report, "", 1);
    // Nothing was imported and nothing was deleted.
    try expectFileExists(photo);
}