const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const createProgram = cli.createProgram;
const parseCommandLine = cli.parseCommandLine;

//
// Checks an optional string option against the value commander produced (missing means undefined).
//
fn expectText(expected: ?std.json.Value, actual: ?[]const u8) !void {
    if (expected) |value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(value.string, actual.?);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Checks an optional boolean option against the value commander produced (missing means undefined).
//
fn expectFlag(expected: ?std.json.Value, actual: ?bool) !void {
    if (expected) |value| {
        try std.testing.expectEqual(value.bool, actual.?);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Checks the options shared by every command.
//
fn expectBase(expected: std.json.ObjectMap, actual: cli.init_cmd.IBaseCommandOptions) !void {
    try expectText(expected.get("db"), actual.db);
    try expectText(expected.get("key"), actual.key);
    try expectFlag(expected.get("verbose"), actual.verbose);
    try expectFlag(expected.get("tools"), actual.tools);
    try expectFlag(expected.get("yes"), actual.yes);
    try expectText(expected.get("cwd"), actual.cwd);
    try expectText(expected.get("sessionId"), actual.sessionId);
    try expectText(expected.get("workers"), actual.workers);
    try expectText(expected.get("timeout"), actual.timeout);
}

//
// What parsing a command line with the psi program did.
//
const IParsed = struct {
    // The outcome.
    outcome: cli.ParseOutcome,

    // What the hook and the actions left for run().
    state: cli.IProgramState,

    // What commander wrote to stdout.
    stdout: []const u8,

    // What commander wrote to stderr.
    stderr: []const u8,
};

//
// Parses a command line with the psi program, capturing what commander writes.
//
fn parse(allocator: std.mem.Allocator, args: []const []const u8) !IParsed {
    const state = try allocator.create(cli.IProgramState);
    state.* = .{
        .allocator = allocator,
    };
    var stdout = std.Io.Writer.Allocating.init(allocator);
    var stderr = std.Io.Writer.Allocating.init(allocator);
    const program = try createProgram(allocator, state);
    _ = program.configureOutput(.{
        .writeOut = &stdout.writer,
        .writeErr = &stderr.writer,
    });
    // The secrets and dbs groups are added with addCommand, so each has an output of its own (commander does not
    // share the program's with them), shared by its subcommands.
    _ = program.findCommand("secrets").?.configureOutput(.{
        .writeOut = &stdout.writer,
        .writeErr = &stderr.writer,
    });
    _ = program.findCommand("dbs").?.configureOutput(.{
        .writeOut = &stdout.writer,
        .writeErr = &stderr.writer,
    });
    const outcome = try parseCommandLine(program, state, args);
    return .{
        .outcome = outcome,
        .state = state.*,
        .stdout = stdout.written(),
        .stderr = stderr.written(),
    };
}

test "command lines parse exactly like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "command-line.json");
    for (fixture.array.items) |commandCase| {
        const args = try helpers.stringArray(allocator, commandCase.object.get("args").?);
        const expected = commandCase.object.get("outcome").?.object;
        const kind = expected.get("kind").?.string;
        const parsed = try parse(allocator, args);
        const outcome = parsed.outcome;
        errdefer std.debug.print("args={f}\n", .{std.json.fmt(args, .{})});
        if (std.mem.eql(u8, kind, "replicate")) {
            const options = expected.get("options").?.object;
            try std.testing.expect(outcome == .replicate);
            const replicateOptions = outcome.replicate;
            try std.testing.expectEqual(expected.get("quiet").?.bool, parsed.state.notificationsQuiet.?);
            try expectBase(options, replicateOptions.base);
            try expectText(options.get("dest"), replicateOptions.dest);
            try expectText(options.get("destKey"), replicateOptions.destKey);
            try expectFlag(options.get("generateKey"), replicateOptions.generateKey);
            try expectText(options.get("path"), replicateOptions.path);
            try expectFlag(options.get("force"), replicateOptions.force);
            try expectFlag(options.get("partial"), replicateOptions.partial);
            try expectFlag(options.get("full"), replicateOptions.full);
        }
        else if (std.mem.eql(u8, kind, "verify")) {
            const options = expected.get("options").?.object;
            try std.testing.expect(outcome == .verify);
            const verifyOptions = outcome.verify;
            try std.testing.expectEqual(expected.get("quiet").?.bool, parsed.state.notificationsQuiet.?);
            try expectBase(options, verifyOptions.base);
            try expectFlag(options.get("full"), verifyOptions.full);
            try expectText(options.get("path"), verifyOptions.path);
        }
        else if (std.mem.eql(u8, kind, "init")) {
            const options = expected.get("options").?.object;
            try std.testing.expect(outcome == .init);
            const initOptions = outcome.init;
            try std.testing.expectEqual(expected.get("quiet").?.bool, parsed.state.notificationsQuiet.?);
            try expectBase(options, initOptions.base);
            try expectFlag(options.get("generateKey"), initOptions.generateKey);
            try expectText(options.get("databaseId"), initOptions.databaseId);
        }
        else if (std.mem.eql(u8, kind, "versionCommand")) {
            try std.testing.expect(outcome == .version);
            try std.testing.expectEqual(expected.get("quiet").?.bool, parsed.state.notificationsQuiet.?);
        }
        else if (std.mem.eql(u8, kind, "error")) {
            try std.testing.expect(outcome == .failure);
            const stderr = expected.get("stderr").?.string;
            try std.testing.expectEqualStrings(stderr, parsed.stderr);
            try std.testing.expectEqualStrings(stderr[0 .. stderr.len - 1], outcome.failure.message);
            try std.testing.expectEqualStrings(expected.get("code").?.string, outcome.failure.code);
            try std.testing.expectEqual(@as(u8, 1), outcome.failure.exitCode);
        }
        else if (std.mem.eql(u8, kind, "help")) {
            // The help of the commands is rendered by the commander port (psi.json checks the text).
            try std.testing.expect(outcome == .failure);
            try std.testing.expectEqualStrings("commander.helpDisplayed", outcome.failure.code);
            try std.testing.expectEqual(@as(u8, 0), outcome.failure.exitCode);
            try std.testing.expect(std.mem.startsWith(u8, parsed.stdout, "Usage: psi "));
        }
        else {
            // --version prints the version.
            try std.testing.expectEqualStrings("version", kind);
            try std.testing.expect(outcome == .versionOption);
        }
    }
}

//
// Checks that parsing a command line stops with a commander error with this code and stderr.
//
fn expectCommanderError(allocator: std.mem.Allocator, args: []const []const u8, code: []const u8, stderr: []const u8) !void {
    const parsed = try parse(allocator, args);
    try std.testing.expect(parsed.outcome == .failure);
    try std.testing.expectEqualStrings(code, parsed.outcome.failure.code);
    try std.testing.expectEqualStrings(stderr, parsed.stderr);
}

test "commands that are not ported fail by name, unknown commands are unknown, and empty command lines show the help" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const empty = try parse(allocator, &.{});
    try std.testing.expect(empty.outcome == .failure);
    try std.testing.expectEqualStrings("commander.help", empty.outcome.failure.code);
    try std.testing.expect(std.mem.startsWith(u8, empty.stderr, "Usage: psi "));

    const help = try parse(allocator, &.{"--help"});
    try std.testing.expect(help.outcome == .failure);
    try std.testing.expectEqualStrings("commander.helpDisplayed", help.outcome.failure.code);
    try std.testing.expect(std.mem.startsWith(u8, help.stdout, "Usage: psi "));

    try std.testing.expectEqualStrings("mcp", (try parse(allocator, &.{"mcp"})).outcome.notPorted);

    // The secrets and dbs groups are not created with .exitOverride(), so they call process.exit themselves. They
    // are added with addCommand, so they have outputs of their own (parse points them at the captures).
    const secretsOption = try parse(allocator, &.{ "secrets", "--db", "x" });
    try std.testing.expectEqual(@as(u8, 1), secretsOption.outcome.processExit);
    const secretsAlone = try parse(allocator, &.{"secrets"});
    try std.testing.expectEqual(@as(u8, 1), secretsAlone.outcome.processExit);

    try expectCommanderError(allocator, &.{ "--db", "x", "replicate" }, "commander.unknownOption", "error: unknown option '--db'\n");
    try expectCommanderError(allocator, &.{"replicate2"}, "commander.unknownCommand", "error: unknown command 'replicate2'\n(Did you mean replicate?)\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "bogus" }, "commander.unknownCommand", "error: unknown command 'bogus'\n");
}

test "examples and help command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const examples = try parse(allocator, &.{"examples"});
    try std.testing.expect(examples.outcome == .examples);
    try std.testing.expectEqual(@as(?bool, false), examples.state.notificationsQuiet);
    try std.testing.expect((try parse(allocator, &.{ "-q", "examples", "--yes" })).outcome == .examples);
    try std.testing.expect((try parse(allocator, &.{ "examples", "-y" })).outcome == .examples);
    try expectCommanderError(allocator, &.{ "examples", "extra" }, "commander.excessArguments", "error: too many arguments for 'examples'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "examples", "--db", "d" }, "commander.unknownOption", "error: unknown option '--db'\n");

    const helpAlone = try parse(allocator, &.{"help"});
    try std.testing.expect(helpAlone.outcome == .help);
    try std.testing.expect(helpAlone.outcome.help == null);
    try std.testing.expectEqualStrings("replicate", (try parse(allocator, &.{ "help", "replicate" })).outcome.help.?);
    try std.testing.expectEqualStrings("bogus", (try parse(allocator, &.{ "-q", "help", "bogus" })).outcome.help.?);
    try expectCommanderError(allocator, &.{ "help", "replicate", "extra" }, "commander.excessArguments", "error: too many arguments for 'help'. Expected 1 argument but got 2.\n");
    try expectCommanderError(allocator, &.{ "help", "--bogus" }, "commander.unknownOption", "error: unknown option '--bogus'\n");
}

test "helpCommand shows the help of the named command, or of the program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state: cli.IProgramState = .{
        .allocator = allocator,
    };

    var stdout = std.Io.Writer.Allocating.init(allocator);
    var stderr = std.Io.Writer.Allocating.init(allocator);
    const program = try createProgram(allocator, &state);
    _ = program.configureOutput(.{
        .writeOut = &stdout.writer,
        .writeErr = &stderr.writer,
    });

    // By alias: the help of the command, which exits with 0 through commander.
    try std.testing.expectEqual(error.CommanderError, cli.helpCommand(program, "rep"));
    try std.testing.expectEqualStrings("commander.help", program.getCommanderError().?.code);
    try std.testing.expectEqual(@as(u8, 0), program.getCommanderError().?.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, stdout.written(), "Usage: psi replicate|rep [options]\n"));
    try std.testing.expectEqualStrings("", stderr.written());
}

test "the help of the program ends with the main examples and the resources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // picocolors turns colour on for every process on Windows; the expected text has none.
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    const text = try cli.mainHelpText(allocator);
    try std.testing.expect(std.mem.startsWith(u8, text, "\n\nGetting help:\n  psi <command> --help    Shows help for a particular command.\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\nExamples:\n  psi init --db ./photos                         Creates a new database in the ./photos directory.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  psi compare --db ./photos --dest ./backup      Compares two databases for differences.\n\nResources:\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "  ➕ New Issue: https://github.com/ashleydavis/photosphere/issues/new"));
}

test "the preAction hook asks for the notifications with the program's quiet flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(?bool, true), (try parse(allocator, &.{ "-q", "ver" })).state.notificationsQuiet);
    try std.testing.expectEqual(@as(?bool, false), (try parse(allocator, &.{"ver"})).state.notificationsQuiet);
    try std.testing.expectEqual(@as(?bool, null), (try parse(allocator, &.{ "ver", "--help" })).state.notificationsQuiet);
}

test "the command definitions match index.ts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state: cli.IProgramState = .{
        .allocator = allocator,
    };
    const program = try createProgram(allocator, &state);
    try std.testing.expectEqualStrings("psi", program.getName());
    try std.testing.expectEqual(@as(usize, 3), program.options.items.len);
    const addDefinition = program.findCommand("a").?;
    try std.testing.expectEqualStrings("add", addDefinition.getName());
    try std.testing.expectEqual(@as(usize, 11), addDefinition.options.items.len);
    const replicateDefinition = program.findCommand("rep").?;
    try std.testing.expectEqualStrings("replicate", replicateDefinition.getName());
    try std.testing.expectEqual(@as(usize, 13), replicateDefinition.options.items.len);
    try std.testing.expectEqual(@as(usize, 9), program.findCommand("cmp").?.options.items.len);
    for ([_][]const u8{ "origin", "set-origin", "root-hash", "database-id" }) |name| {
        try std.testing.expectEqual(@as(usize, 5), program.findCommand(name).?.options.items.len);
    }
    const infoDefinition = program.findCommand("inf").?;
    try std.testing.expectEqualStrings("info", infoDefinition.getName());
    try std.testing.expectEqual(@as(usize, 5), infoDefinition.options.items.len);
    const listDefinition = program.findCommand("ls").?;
    try std.testing.expectEqualStrings("list", listDefinition.getName());
    try std.testing.expect(program.findCommand("l").? == listDefinition);
    try std.testing.expectEqual(@as(usize, 6), listDefinition.options.items.len);
    const summaryDefinition = program.findCommand("sum").?;
    try std.testing.expectEqualStrings("summary", summaryDefinition.getName());
    try std.testing.expectEqual(@as(usize, 5), summaryDefinition.options.items.len);
    const verifyDefinition = program.findCommand("ver").?;
    try std.testing.expectEqualStrings("verify", verifyDefinition.getName());
    try std.testing.expectEqual(@as(usize, 10), verifyDefinition.options.items.len);
    const initDefinition = program.findCommand("i").?;
    try std.testing.expectEqualStrings("init", initDefinition.getName());
    try std.testing.expectEqual(@as(usize, 9), initDefinition.options.items.len);
    const versionDefinition = program.findCommand("version").?;
    try std.testing.expectEqualStrings("version", versionDefinition.getName());
    try std.testing.expectEqual(@as(usize, 0), versionDefinition.options.items.len);
    try std.testing.expectEqualStrings("Task timeout in milliseconds (default: 600000 = 10 minutes)", cli.timeoutOption.description);
}

test "add command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The files are the variadic [files...] argument; --dry-run, --watch and --cleanup default to false (index.ts).
    const plain = try parse(allocator, &.{ "add", "--db", "a", "x.jpg", "dir", "--yes" });
    try std.testing.expect(plain.outcome == .add);
    try std.testing.expectEqual(@as(usize, 2), plain.outcome.add.paths.len);
    try std.testing.expectEqualStrings("x.jpg", plain.outcome.add.paths[0]);
    try std.testing.expectEqualStrings("dir", plain.outcome.add.paths[1]);
    try std.testing.expectEqualStrings("a", plain.outcome.add.options.base.db.?);
    try std.testing.expectEqual(@as(?bool, true), plain.outcome.add.options.base.yes);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.add.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.add.options.dryRun);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.add.options.watch);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.add.options.cleanup);
    try std.testing.expectEqual(@as(?bool, false), plain.state.notificationsQuiet);

    // The alias, every option of the command, and no files.
    const everything = try parse(allocator, &.{ "-q", "a", "-k", "key1", "-v", "--tools", "--cwd", "/tmp", "--session-id", "s1", "--dry-run", "--workers", "3", "--watch", "--cleanup" });
    try std.testing.expect(everything.outcome == .add);
    try std.testing.expectEqual(@as(usize, 0), everything.outcome.add.paths.len);
    try std.testing.expectEqual(@as(?[]const u8, null), everything.outcome.add.options.base.db);
    try std.testing.expectEqualStrings("key1", everything.outcome.add.options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.add.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.add.options.base.tools);
    try std.testing.expectEqual(@as(?bool, false), everything.outcome.add.options.base.yes);
    try std.testing.expectEqualStrings("/tmp", everything.outcome.add.options.base.cwd.?);
    try std.testing.expectEqualStrings("s1", everything.outcome.add.options.base.sessionId.?);
    try std.testing.expectEqualStrings("3", everything.outcome.add.options.base.workers.?);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.add.options.dryRun);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.add.options.watch);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.add.options.cleanup);
    try std.testing.expectEqual(@as(?bool, true), everything.state.notificationsQuiet);

    // Each flag sets only its own option.
    const cleanupOnly = try parse(allocator, &.{ "add", "--cleanup" });
    try std.testing.expectEqual(@as(?bool, true), cleanupOnly.outcome.add.options.cleanup);
    try std.testing.expectEqual(@as(?bool, false), cleanupOnly.outcome.add.options.watch);
    try std.testing.expectEqual(@as(?bool, false), cleanupOnly.outcome.add.options.dryRun);
    const watchOnly = try parse(allocator, &.{ "add", "--watch" });
    try std.testing.expectEqual(@as(?bool, false), watchOnly.outcome.add.options.cleanup);
    try std.testing.expectEqual(@as(?bool, true), watchOnly.outcome.add.options.watch);
    try std.testing.expectEqual(@as(?bool, false), watchOnly.outcome.add.options.dryRun);

    // add has no --timeout option, and --help shows the help of the command.
    try expectCommanderError(allocator, &.{ "add", "--timeout", "5" }, "commander.unknownOption", "error: unknown option '--timeout'\n");
    const help = try parse(allocator, &.{ "add", "--help" });
    try std.testing.expect(help.outcome == .failure);
    try std.testing.expectEqualStrings("commander.helpDisplayed", help.outcome.failure.code);
    try std.testing.expect(std.mem.startsWith(u8, help.stdout, "Usage: psi add|a [options] [files...]\n\nAdds files and directories to the media file database"));
}

test "handleError reports fatal errors in red without the bug report hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const utils = @import("utils-zig");
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);

    const fatal = utils.errors.throwFatalError("Something fatal", .{});
    cli.handleError(allocator, fatal, null);
    try std.testing.expectEqualStrings("\n\nSomething fatal\n", stderr_capture.written());
    try std.testing.expectEqualStrings("", stdout_capture.written());
}

test "handleError reports other errors with the bug report hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const utils = @import("utils-zig");
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);

    const thrown = utils.errors.throwError("Broken", .{});
    cli.handleError(allocator, thrown, null);
    try std.testing.expectEqualStrings("An unknown error occurred\nError: Broken\n", stderr_capture.written());
    try std.testing.expectEqualStrings("\nIf you believe this behaviour is a bug, please report it with the following command:\n   psi bug\n", stdout_capture.written());

    stderr_capture.clearRetainingCapacity();
    cli.handleError(allocator, error.OutOfMemory, "uncaught exception");
    try std.testing.expectEqualStrings("An uncaught exception error occurred\nError: OutOfMemory\n", stderr_capture.written());
}

test "--version is handled in Zig wherever it is given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try parse(allocator, &.{"--version"})).outcome == .versionOption);
    try std.testing.expect((try parse(allocator, &.{ "rep", "--version" })).outcome == .versionOption);
    try std.testing.expect((try parse(allocator, &.{ "version", "--version" })).outcome == .versionOption);
}

test "summary command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "sum", "--db", "a", "--key", "k", "--verbose", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .summary);
    const options = parsed.outcome.summary.base;
    try std.testing.expectEqualStrings("a", options.db.?);
    try std.testing.expectEqualStrings("k", options.key.?);
    try std.testing.expectEqual(@as(?bool, true), options.verbose);
    try std.testing.expectEqual(@as(?bool, true), options.yes);
    try std.testing.expectEqualStrings("c", options.cwd.?);

    const unknown = try parse(allocator, &.{ "summary", "--full" });
    try std.testing.expect(unknown.outcome == .failure);
    try std.testing.expectEqualStrings("commander.unknownOption", unknown.outcome.failure.code);
}

test "list command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "ls", "--db", "a", "--key", "k", "--verbose", "--yes", "--cwd", "c", "--page-size", "10" });
    try std.testing.expect(parsed.outcome == .list);
    const options = parsed.outcome.list;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqualStrings("10", options.pageSize.?);

    // The page size defaults to "20".
    const defaulted = try parse(allocator, &.{"l"});
    try std.testing.expect(defaulted.outcome == .list);
    try std.testing.expectEqualStrings("20", defaulted.outcome.list.pageSize.?);

    const unknown = try parse(allocator, &.{ "list", "--full" });
    try std.testing.expect(unknown.outcome == .failure);
    try std.testing.expectEqualStrings("commander.unknownOption", unknown.outcome.failure.code);
}

test "info command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "inf", "a.jpg", "b.jpg", "--db", "d", "--verbose", "--tools", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .info);
    const info = parsed.outcome.info;
    try std.testing.expectEqual(@as(usize, 2), info.inputs.len);
    try std.testing.expectEqualStrings("a.jpg", info.inputs[0]);
    try std.testing.expectEqualStrings("b.jpg", info.inputs[1]);
    try std.testing.expectEqualStrings("d", info.options.base.db.?);
    try std.testing.expectEqual(@as(?bool, true), info.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), info.options.base.tools);
    try std.testing.expectEqual(@as(?bool, true), info.options.base.yes);
    try std.testing.expectEqualStrings("c", info.options.base.cwd.?);

    // <files...> is required.
    try expectCommanderError(allocator, &.{"info"}, "commander.missingArgument", "error: missing required argument 'files'\n");

    const unknown = try parse(allocator, &.{ "info", "a.jpg", "--key", "k" });
    try std.testing.expect(unknown.outcome == .failure);
    try std.testing.expectEqualStrings("commander.unknownOption", unknown.outcome.failure.code);
}

test "info classifies inputs as paths, asset IDs or hashes" {
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9-a652-4047-b869-1154bf2c95a1"), .assetId);
    try std.testing.expectEqual(cli.info.classifyInput("89171CD9-A652-4047-B869-1154BF2C95A1"), .assetId);
    try std.testing.expectEqual(cli.info.classifyInput("426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c"), .hash);
    try std.testing.expectEqual(cli.info.classifyInput("426FAB8DBDD88EAD05220E0A73644B1D77C4591689701090926129AF8BA45E7C"), .hash);
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9a652-4047-b869-1154bf2c95a1-"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("photo.jpg"), .path);
    try std.testing.expectEqual(cli.info.classifyInput("89171cd9-a652-4047-b869-1154bf2c95ag"), .path);
}

test "origin, set-origin, root-hash and database-id command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const origin = try parse(allocator, &.{ "origin", "--db", "a", "--key", "k", "--yes" });
    try std.testing.expect(origin.outcome == .origin);
    try std.testing.expectEqualStrings("a", origin.outcome.origin.base.db.?);
    try std.testing.expectEqualStrings("k", origin.outcome.origin.base.key.?);

    const setOrigin = try parse(allocator, &.{ "set-origin", "s3:b/p", "--db", "a", "--verbose" });
    try std.testing.expect(setOrigin.outcome == .setOrigin);
    try std.testing.expectEqualStrings("s3:b/p", setOrigin.outcome.setOrigin.path);
    try std.testing.expectEqualStrings("a", setOrigin.outcome.setOrigin.options.base.db.?);
    try std.testing.expectEqual(@as(?bool, true), setOrigin.outcome.setOrigin.options.base.verbose);
    try expectCommanderError(allocator, &.{"set-origin"}, "commander.missingArgument", "error: missing required argument 'path'\n");

    const rootHash = try parse(allocator, &.{ "root-hash", "--cwd", "c" });
    try std.testing.expect(rootHash.outcome == .rootHash);
    try std.testing.expectEqualStrings("c", rootHash.outcome.rootHash.base.cwd.?);

    const databaseId = try parse(allocator, &.{ "database-id", "--db", "d" });
    try std.testing.expect(databaseId.outcome == .databaseId);
    try std.testing.expectEqualStrings("d", databaseId.outcome.databaseId.base.db.?);
}

test "export command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "exp", "id-1", "out.jpg", "--db", "d", "--key", "k", "-t", "thumb", "--verbose", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .@"export");
    const exported = parsed.outcome.@"export";
    try std.testing.expectEqualStrings("id-1", exported.assetId);
    try std.testing.expectEqualStrings("out.jpg", exported.outputPath);
    try std.testing.expectEqualStrings("d", exported.options.base.db.?);
    try std.testing.expectEqualStrings("k", exported.options.base.key.?);
    try std.testing.expectEqualStrings("thumb", exported.options.type.?);
    try std.testing.expectEqual(@as(?bool, true), exported.options.base.verbose);
    try std.testing.expectEqualStrings("c", exported.options.base.cwd.?);

    // The type defaults to "original".
    const defaulted = try parse(allocator, &.{ "export", "id-1", "out.jpg" });
    try std.testing.expectEqualStrings("original", defaulted.outcome.@"export".options.type.?);

    try expectCommanderError(allocator, &.{ "export", "id-1" }, "commander.missingArgument", "error: missing required argument 'output-path'\n");
}

test "compare command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "cmp", "--db", "a", "--dest", "b", "--key", "k", "--dk", "dk", "--full", "--max", "20", "--yes" });
    try std.testing.expect(parsed.outcome == .compare);
    const options = parsed.outcome.compare;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("b", options.dest.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqualStrings("dk", options.destKey.?);
    try std.testing.expectEqual(@as(?bool, true), options.full);
    try std.testing.expectEqualStrings("20", options.max.?);

    const longKey = try parse(allocator, &.{ "compare", "--dest-key", "x" });
    try std.testing.expectEqualStrings("x", longKey.outcome.compare.destKey.?);
    try std.testing.expectEqual(@as(?bool, false), longKey.outcome.compare.full);
    try std.testing.expect(longKey.outcome.compare.max == null);
}

test "repair command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "repair", "--db", "a", "--source", "b", "--key", "k", "--sk", "sk", "--full", "--yes" });
    try std.testing.expect(parsed.outcome == .repair);
    const options = parsed.outcome.repair;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("b", options.source.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqualStrings("sk", options.sourceKey.?);
    try std.testing.expectEqual(@as(?bool, true), options.full);

    const longKey = try parse(allocator, &.{ "repair", "--source-key", "x" });
    try std.testing.expectEqualStrings("x", longKey.outcome.repair.sourceKey.?);
    try std.testing.expectEqual(@as(?bool, false), longKey.outcome.repair.full);
    try std.testing.expect(longKey.outcome.repair.source == null);
}

test "find-orphans command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "find-orphans", "--db", "a", "--key", "k", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .findOrphans);
    const options = parsed.outcome.findOrphans;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try expectCommanderError(allocator, &.{ "find-orphans", "extra" }, "commander.excessArguments", "error: too many arguments for 'find-orphans'. Expected 0 arguments but got 1.\n");
}

test "remove-orphans command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "remove-orphans", "--db", "a", "--key", "k", "--yes", "--verbose" });
    try std.testing.expect(parsed.outcome == .removeOrphans);
    const options = parsed.outcome.removeOrphans;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try std.testing.expectEqual(@as(?bool, true), options.base.verbose);
    try expectCommanderError(allocator, &.{ "remove-orphans", "extra" }, "commander.excessArguments", "error: too many arguments for 'remove-orphans'. Expected 0 arguments but got 1.\n");
}

test "upgrade command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "upgrade", "--db", "a", "--key", "k", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .upgrade);
    const options = parsed.outcome.upgrade;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try expectCommanderError(allocator, &.{ "upgrade", "extra" }, "commander.excessArguments", "error: too many arguments for 'upgrade'. Expected 0 arguments but got 1.\n");
}

test "sync command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "sync", "--db", "a", "--dest", "b", "--key", "k", "--dk", "dk", "--watch", "--interval", "60", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .sync);
    const options = parsed.outcome.sync;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("b", options.dest.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqualStrings("dk", options.destKey.?);
    try std.testing.expectEqual(@as(?bool, true), options.watch);
    try std.testing.expectEqualStrings("60", options.interval.?);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);

    const defaults = try parse(allocator, &.{ "sync", "--dest-key", "x" });
    try std.testing.expectEqualStrings("x", defaults.outcome.sync.destKey.?);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.sync.watch);
    try std.testing.expect(defaults.outcome.sync.interval == null);
    try std.testing.expect(defaults.outcome.sync.dest == null);
    try expectCommanderError(allocator, &.{ "sync", "extra" }, "commander.excessArguments", "error: too many arguments for 'sync'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "sync", "--interval" }, "commander.optionMissingArgument", "error: option '--interval <seconds>' argument missing\n");
}

test "consolidate command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "consolidate", "s3:b/p", "--db", "a", "--key", "k", "--dk", "dk", "--verbose", "--yes", "--cwd", "c", "--session-id", "s1" });
    try std.testing.expect(parsed.outcome == .consolidate);
    const consolidate = parsed.outcome.consolidate;
    try std.testing.expectEqualStrings("s3:b/p", consolidate.remote);
    try std.testing.expectEqualStrings("a", consolidate.options.base.db.?);
    try std.testing.expectEqualStrings("k", consolidate.options.base.key.?);
    try std.testing.expectEqualStrings("dk", consolidate.options.destKey.?);
    try std.testing.expectEqual(@as(?bool, true), consolidate.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), consolidate.options.base.yes);
    try std.testing.expectEqualStrings("c", consolidate.options.base.cwd.?);
    try std.testing.expectEqualStrings("s1", consolidate.options.base.sessionId.?);

    const defaults = try parse(allocator, &.{ "consolidate", "./remote", "--dest-key", "x" });
    try std.testing.expectEqualStrings("./remote", defaults.outcome.consolidate.remote);
    try std.testing.expectEqualStrings("x", defaults.outcome.consolidate.options.destKey.?);
    try std.testing.expect(defaults.outcome.consolidate.options.base.db == null);
    try expectCommanderError(allocator, &.{"consolidate"}, "commander.missingArgument", "error: missing required argument 'remote'\n");
    try expectCommanderError(allocator, &.{ "consolidate", "a", "b" }, "commander.excessArguments", "error: too many arguments for 'consolidate'. Expected 1 argument but got 2.\n");
}

test "encrypt command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "encrypt", "--db", "a", "--key", "k", "--generate-key", "--yes", "--cwd", "c", "--verbose" });
    try std.testing.expect(parsed.outcome == .encrypt);
    const options = parsed.outcome.encrypt;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), options.generateKey);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.verbose);

    const short = try parse(allocator, &.{ "encrypt", "-k", "new,old", "-g", "-y", "-v" });
    try std.testing.expectEqualStrings("new,old", short.outcome.encrypt.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.encrypt.generateKey);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.encrypt.base.yes);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.encrypt.base.verbose);

    const defaults = try parse(allocator, &.{"encrypt"});
    try std.testing.expect(defaults.outcome.encrypt.base.db == null);
    try std.testing.expect(defaults.outcome.encrypt.base.key == null);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.encrypt.generateKey);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.encrypt.base.yes);
    try expectCommanderError(allocator, &.{ "encrypt", "extra" }, "commander.excessArguments", "error: too many arguments for 'encrypt'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "encrypt", "--key" }, "commander.optionMissingArgument", "error: option '-k, --key <keyfile>' argument missing\n");
    try expectCommanderError(allocator, &.{ "encrypt", "--session-id", "s1" }, "commander.unknownOption", "error: unknown option '--session-id'\n");
}

test "decrypt command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "decrypt", "--db", "a", "--key", "k", "--yes", "--cwd", "c", "--verbose" });
    try std.testing.expect(parsed.outcome == .decrypt);
    const options = parsed.outcome.decrypt;
    try std.testing.expectEqualStrings("a", options.base.db.?);
    try std.testing.expectEqualStrings("k", options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.yes);
    try std.testing.expectEqualStrings("c", options.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), options.base.verbose);

    const short = try parse(allocator, &.{ "decrypt", "-k", "new,old", "-y", "-v" });
    try std.testing.expectEqualStrings("new,old", short.outcome.decrypt.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.decrypt.base.yes);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.decrypt.base.verbose);

    const defaults = try parse(allocator, &.{"decrypt"});
    try std.testing.expect(defaults.outcome.decrypt.base.db == null);
    try std.testing.expect(defaults.outcome.decrypt.base.key == null);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.decrypt.base.yes);
    try expectCommanderError(allocator, &.{ "decrypt", "extra" }, "commander.excessArguments", "error: too many arguments for 'decrypt'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "decrypt", "--key" }, "commander.optionMissingArgument", "error: option '-k, --key <keyfile>' argument missing\n");
    try expectCommanderError(allocator, &.{ "decrypt", "--generate-key" }, "commander.unknownOption", "error: unknown option '--generate-key'\n");
}

test "hash command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "hash", "photo.jpg", "--key", "k", "--verbose", "--yes", "--cwd", "c" });
    try std.testing.expect(parsed.outcome == .hash);
    const hashed = parsed.outcome.hash;
    try std.testing.expectEqualStrings("photo.jpg", hashed.filePath);
    try std.testing.expectEqualStrings("k", hashed.options.key.?);
    try std.testing.expectEqual(@as(?bool, true), hashed.options.verbose);
    try std.testing.expectEqual(@as(?bool, true), hashed.options.yes);

    const short = try parse(allocator, &.{ "hash", "-k", "new,old", "-y", "-v", "s3:bucket/photo.jpg" });
    try std.testing.expectEqualStrings("s3:bucket/photo.jpg", short.outcome.hash.filePath);
    try std.testing.expectEqualStrings("new,old", short.outcome.hash.options.key.?);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.hash.options.yes);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.hash.options.verbose);

    const defaults = try parse(allocator, &.{ "hash", "photo.jpg" });
    try std.testing.expect(defaults.outcome.hash.options.key == null);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.hash.options.yes);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.hash.options.verbose);

    const onlyYes = try parse(allocator, &.{ "hash", "--yes", "photo.jpg" });
    try std.testing.expectEqual(@as(?bool, true), onlyYes.outcome.hash.options.yes);
    try std.testing.expectEqual(@as(?bool, false), onlyYes.outcome.hash.options.verbose);

    try expectCommanderError(allocator, &.{"hash"}, "commander.missingArgument", "error: missing required argument 'file-path'\n");
    try expectCommanderError(allocator, &.{ "hash", "a", "b" }, "commander.excessArguments", "error: too many arguments for 'hash'. Expected 1 argument but got 2.\n");
    try expectCommanderError(allocator, &.{ "hash", "--key" }, "commander.optionMissingArgument", "error: option '-k, --key <keyfile>' argument missing\n");
    try expectCommanderError(allocator, &.{ "hash", "a", "--db", "d" }, "commander.unknownOption", "error: unknown option '--db'\n");
}

test "tools command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "tools", "--yes" });
    try std.testing.expect(parsed.outcome == .tools);
    try std.testing.expectEqual(@as(?bool, true), parsed.outcome.tools.yes);

    const short = try parse(allocator, &.{ "tools", "-y" });
    try std.testing.expectEqual(@as(?bool, true), short.outcome.tools.yes);

    const defaults = try parse(allocator, &.{"tools"});
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.tools.yes);
    try expectCommanderError(allocator, &.{ "tools", "extra" }, "commander.excessArguments", "error: too many arguments for 'tools'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "tools", "--db", "d" }, "commander.unknownOption", "error: unknown option '--db'\n");
    try expectCommanderError(allocator, &.{ "tools", "--verbose" }, "commander.unknownOption", "error: unknown option '--verbose'\n");
}

test "check command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The files are the required variadic <files...> argument (index.ts).
    const plain = try parse(allocator, &.{ "check", "--db", "a", "x.jpg", "dir", "--yes" });
    try std.testing.expect(plain.outcome == .check);
    try std.testing.expectEqual(@as(usize, 2), plain.outcome.check.paths.len);
    try std.testing.expectEqualStrings("x.jpg", plain.outcome.check.paths[0]);
    try std.testing.expectEqualStrings("dir", plain.outcome.check.paths[1]);
    try std.testing.expectEqualStrings("a", plain.outcome.check.options.base.db.?);
    try std.testing.expectEqual(@as(?bool, true), plain.outcome.check.options.base.yes);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.check.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, false), plain.outcome.check.options.base.tools);

    // The alias and every option of the command.
    const everything = try parse(allocator, &.{ "chk", "-k", "key1", "-v", "--tools", "--workers", "3", "--timeout", "1000", "--cwd", "/tmp", "x.jpg" });
    try std.testing.expect(everything.outcome == .check);
    try std.testing.expectEqual(@as(usize, 1), everything.outcome.check.paths.len);
    try std.testing.expectEqual(@as(?[]const u8, null), everything.outcome.check.options.base.db);
    try std.testing.expectEqualStrings("key1", everything.outcome.check.options.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.check.options.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), everything.outcome.check.options.base.tools);
    try std.testing.expectEqual(@as(?bool, false), everything.outcome.check.options.base.yes);
    try std.testing.expectEqualStrings("3", everything.outcome.check.options.base.workers.?);
    try std.testing.expectEqualStrings("1000", everything.outcome.check.options.base.timeout.?);
    try std.testing.expectEqualStrings("/tmp", everything.outcome.check.options.base.cwd.?);

    try expectCommanderError(allocator, &.{"check"}, "commander.missingArgument", "error: missing required argument 'files'\n");
    try expectCommanderError(allocator, &.{ "check", "x.jpg", "--session-id", "s1" }, "commander.unknownOption", "error: unknown option '--session-id'\n");
    try expectCommanderError(allocator, &.{ "check", "x.jpg", "--key" }, "commander.optionMissingArgument", "error: option '-k, --key <keyfile>' argument missing\n");
}

test "remove command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "rm", "id-1", "--db", "d", "--key", "k", "--yes" });
    try std.testing.expect(parsed.outcome == .remove);
    try std.testing.expectEqualStrings("id-1", parsed.outcome.remove.assetId);
    try std.testing.expectEqualStrings("d", parsed.outcome.remove.options.base.db.?);
    try std.testing.expectEqualStrings("k", parsed.outcome.remove.options.base.key.?);
    try expectCommanderError(allocator, &.{"remove"}, "commander.missingArgument", "error: missing required argument 'asset-id'\n");
}

//
// Checks that parsing a command line of the secrets or dbs group ended the process like commander's process.exit (the
// group is added with addCommand, so it does not inherit the program's exitOverride), with this exit code and
// stderr.
//
fn expectSecretsExit(allocator: std.mem.Allocator, args: []const []const u8, exitCode: u8, stderr: []const u8) !void {
    const parsed = try parse(allocator, args);
    try std.testing.expect(parsed.outcome == .processExit);
    try std.testing.expectEqual(exitCode, parsed.outcome.processExit);
    try std.testing.expectEqualStrings(stderr, parsed.stderr);
}

test "secrets command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const add = try parse(allocator, &.{ "secrets", "add", "--yes", "--name", "n", "--type", "plain", "--value", "v" });
    try std.testing.expect(add.outcome == .secretsAdd);
    try std.testing.expectEqual(@as(?bool, true), add.outcome.secretsAdd.yes);
    try std.testing.expectEqualStrings("n", add.outcome.secretsAdd.name.?);
    try std.testing.expectEqualStrings("plain", add.outcome.secretsAdd.type.?);
    try std.testing.expectEqualStrings("v", add.outcome.secretsAdd.value.?);
    try std.testing.expectEqual(@as(?bool, false), add.state.notificationsQuiet);

    // The options have no defaults: an option not given is undefined.
    const addDefaults = try parse(allocator, &.{ "-q", "sec", "add" });
    try std.testing.expect(addDefaults.outcome.secretsAdd.yes == null);
    try std.testing.expect(addDefaults.outcome.secretsAdd.name == null);
    try std.testing.expectEqual(@as(?bool, true), addDefaults.state.notificationsQuiet);

    try std.testing.expect((try parse(allocator, &.{ "secrets", "list" })).outcome == .secretsList);
    try std.testing.expect((try parse(allocator, &.{ "s", "l" })).outcome == .secretsList);
    try std.testing.expect((try parse(allocator, &.{ "sec", "ls" })).outcome == .secretsList);

    const view = try parse(allocator, &.{ "secrets", "v", "--name", "k", "--yes", "--raw" });
    try std.testing.expect(view.outcome == .secretsView);
    try std.testing.expectEqualStrings("k", view.outcome.secretsView.name.?);
    try std.testing.expectEqual(@as(?bool, true), view.outcome.secretsView.yes);
    try std.testing.expectEqual(@as(?bool, true), view.outcome.secretsView.raw);

    const edit = try parse(allocator, &.{ "secrets", "e", "--name", "k", "--new-name", "k2", "--value", "v", "--value-file", "f", "--yes" });
    try std.testing.expect(edit.outcome == .secretsEdit);
    try std.testing.expectEqualStrings("k", edit.outcome.secretsEdit.name.?);
    try std.testing.expectEqualStrings("k2", edit.outcome.secretsEdit.newName.?);
    try std.testing.expectEqualStrings("v", edit.outcome.secretsEdit.value.?);
    try std.testing.expectEqualStrings("f", edit.outcome.secretsEdit.valueFile.?);
    try std.testing.expectEqual(@as(?bool, true), edit.outcome.secretsEdit.yes);

    const remove = try parse(allocator, &.{ "secrets", "remove", "--name", "k" });
    try std.testing.expect(remove.outcome == .secretsRemove);
    try std.testing.expectEqualStrings("k", remove.outcome.secretsRemove.name.?);
    try std.testing.expect(remove.outcome.secretsRemove.yes == null);

    const clear = try parse(allocator, &.{ "secrets", "clear", "--yes" });
    try std.testing.expect(clear.outcome == .secretsClear);
    try std.testing.expectEqual(@as(?bool, true), clear.outcome.secretsClear.yes);

    const import = try parse(allocator, &.{ "secrets", "import", "--private-key", "a.key", "--yes" });
    try std.testing.expect(import.outcome == .secretsImport);
    try std.testing.expectEqualStrings("a.key", import.outcome.secretsImport.privateKey.?);

    const send = try parse(allocator, &.{ "secrets", "send", "--name", "k", "--code", "1234", "--yes" });
    try std.testing.expect(send.outcome == .secretsSend);
    try std.testing.expectEqualStrings("k", send.outcome.secretsSend.name.?);
    try std.testing.expectEqualStrings("1234", send.outcome.secretsSend.code.?);

    const receive = try parse(allocator, &.{ "secrets", "receive", "--code", "1234", "--yes" });
    try std.testing.expect(receive.outcome == .secretsReceive);
    try std.testing.expectEqualStrings("1234", receive.outcome.secretsReceive.code.?);
    try std.testing.expectEqual(@as(?bool, true), receive.outcome.secretsReceive.yes);

    // Errors end the process with code 1, as commander does for a command without the program's exitOverride.
    try expectSecretsExit(allocator, &.{ "secrets", "bogus" }, 1, "error: unknown command 'bogus'\n");
    try expectSecretsExit(allocator, &.{ "secrets", "view", "--bogus" }, 1, "error: unknown option '--bogus'\n");
    try expectSecretsExit(allocator, &.{ "secrets", "edit", "--name" }, 1, "error: option '--name <name>' argument missing\n");
    try expectSecretsExit(allocator, &.{ "secrets", "list", "extra" }, 1, "error: too many arguments for 'list'. Expected 0 arguments but got 1.\n");
}

test "the secrets group shows its help like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expectedHelp =
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

    // --help writes the help to stdout and exits with 0.
    const help = try parse(allocator, &.{ "secrets", "--help" });
    try std.testing.expect(help.outcome == .processExit);
    try std.testing.expectEqual(@as(u8, 0), help.outcome.processExit);
    try std.testing.expectEqualStrings(expectedHelp, help.stdout);

    // With no subcommand the help goes to stderr and the exit code is 1.
    const bare = try parse(allocator, &.{"secrets"});
    try std.testing.expect(bare.outcome == .processExit);
    try std.testing.expectEqual(@as(u8, 1), bare.outcome.processExit);
    try std.testing.expectEqualStrings(expectedHelp, bare.stderr);
}

test "debug command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const merkleTree = try parse(allocator, &.{ "debug", "merkle-tree", "--db", "a", "--key", "k", "--yes", "--cwd", "c", "--verbose", "--records", "--all" });
    try std.testing.expect(merkleTree.outcome == .debugMerkleTree);
    try std.testing.expectEqualStrings("a", merkleTree.outcome.debugMerkleTree.base.db.?);
    try std.testing.expectEqualStrings("k", merkleTree.outcome.debugMerkleTree.base.key.?);
    try std.testing.expectEqualStrings("c", merkleTree.outcome.debugMerkleTree.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), merkleTree.outcome.debugMerkleTree.base.yes);
    try std.testing.expectEqual(@as(?bool, true), merkleTree.outcome.debugMerkleTree.base.verbose);
    try std.testing.expectEqual(@as(?bool, true), merkleTree.outcome.debugMerkleTree.records);
    try std.testing.expectEqual(@as(?bool, true), merkleTree.outcome.debugMerkleTree.all);
    try std.testing.expectEqual(@as(?bool, false), merkleTree.state.notificationsQuiet);

    const merkleTreeDefaults = try parse(allocator, &.{ "debug", "merkle-tree" });
    try std.testing.expect(merkleTreeDefaults.outcome.debugMerkleTree.base.db == null);
    try std.testing.expectEqual(@as(?bool, false), merkleTreeDefaults.outcome.debugMerkleTree.records);
    try std.testing.expectEqual(@as(?bool, false), merkleTreeDefaults.outcome.debugMerkleTree.all);
    try std.testing.expectEqual(@as(?bool, false), merkleTreeDefaults.outcome.debugMerkleTree.base.yes);

    const recordsOnly = try parse(allocator, &.{ "debug", "merkle-tree", "--records" });
    try std.testing.expectEqual(@as(?bool, true), recordsOnly.outcome.debugMerkleTree.records);
    try std.testing.expectEqual(@as(?bool, false), recordsOnly.outcome.debugMerkleTree.all);
    const allOnly = try parse(allocator, &.{ "debug", "merkle-tree", "--all" });
    try std.testing.expectEqual(@as(?bool, false), allOnly.outcome.debugMerkleTree.records);
    try std.testing.expectEqual(@as(?bool, true), allOnly.outcome.debugMerkleTree.all);

    const findCollisions = try parse(allocator, &.{ "debug", "find-collisions", "--db", "a", "-o", "out.json" });
    try std.testing.expect(findCollisions.outcome == .debugFindCollisions);
    try std.testing.expectEqualStrings("a", findCollisions.outcome.debugFindCollisions.base.db.?);
    try std.testing.expectEqualStrings("out.json", findCollisions.outcome.debugFindCollisions.output.?);
    try std.testing.expectEqualStrings("collisions.json", (try parse(allocator, &.{ "debug", "find-collisions" })).outcome.debugFindCollisions.output.?);

    const findDuplicates = try parse(allocator, &.{ "debug", "find-duplicates", "--input", "in.json", "--output", "out.json", "-y" });
    try std.testing.expect(findDuplicates.outcome == .debugFindDuplicates);
    try std.testing.expectEqualStrings("in.json", findDuplicates.outcome.debugFindDuplicates.input.?);
    try std.testing.expectEqualStrings("out.json", findDuplicates.outcome.debugFindDuplicates.output.?);
    try std.testing.expectEqual(@as(?bool, true), findDuplicates.outcome.debugFindDuplicates.base.yes);
    const findDuplicatesDefaults = try parse(allocator, &.{ "debug", "find-duplicates" });
    try std.testing.expectEqualStrings("collisions.json", findDuplicatesDefaults.outcome.debugFindDuplicates.input.?);
    try std.testing.expectEqualStrings("duplicates.json", findDuplicatesDefaults.outcome.debugFindDuplicates.output.?);

    const removeDuplicates = try parse(allocator, &.{ "debug", "remove-duplicates", "-i", "in.json", "-k", "k" });
    try std.testing.expect(removeDuplicates.outcome == .debugRemoveDuplicates);
    try std.testing.expectEqualStrings("in.json", removeDuplicates.outcome.debugRemoveDuplicates.input.?);
    try std.testing.expectEqualStrings("k", removeDuplicates.outcome.debugRemoveDuplicates.base.key.?);
    try std.testing.expectEqualStrings("duplicates.json", (try parse(allocator, &.{ "debug", "remove-duplicates" })).outcome.debugRemoveDuplicates.input.?);

    const buildSortIndex = try parse(allocator, &.{ "debug", "build-sort-index", "--db", "a", "-v" });
    try std.testing.expect(buildSortIndex.outcome == .debugBuildSortIndex);
    try std.testing.expectEqualStrings("a", buildSortIndex.outcome.debugBuildSortIndex.db.?);
    try std.testing.expectEqual(@as(?bool, true), buildSortIndex.outcome.debugBuildSortIndex.verbose);

    const buildFilesTree = try parse(allocator, &.{ "-q", "debug", "build-files-tree", "--db", "a" });
    try std.testing.expect(buildFilesTree.outcome == .debugBuildFilesTree);
    try std.testing.expectEqualStrings("a", buildFilesTree.outcome.debugBuildFilesTree.db.?);
    try std.testing.expectEqual(@as(?bool, true), buildFilesTree.state.notificationsQuiet);

    // With no subcommand the group shows its help, like commander does for a command with subcommands and no action.
    const group = try parse(allocator, &.{"debug"});
    try std.testing.expect(group.outcome == .failure);
    try std.testing.expectEqualStrings("commander.help", group.outcome.failure.code);
    try std.testing.expect(std.mem.startsWith(u8, group.stderr, "Usage: psi debug [options] [command]\n\nDebug commands for inspecting database internals.\n"));

    try expectCommanderError(allocator, &.{ "debug", "nope" }, "commander.unknownCommand", "error: unknown command 'nope'\n");
    try expectCommanderError(allocator, &.{ "debug", "merkle-tree", "extra" }, "commander.excessArguments", "error: too many arguments for 'merkle-tree'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "debug", "find-collisions", "--output" }, "commander.optionMissingArgument", "error: option '-o, --output <path>' argument missing\n");
    try expectCommanderError(allocator, &.{ "debug", "build-sort-index", "--records" }, "commander.unknownOption", "error: unknown option '--records'\n");
}

test "hash-cache command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const show = try parse(allocator, &.{ "hash-cache", "show", "--db", "a", "--key", "k", "--yes", "--cwd", "c", "--verbose" });
    try std.testing.expect(show.outcome == .hashCacheShow);
    try std.testing.expectEqualStrings("a", show.outcome.hashCacheShow.base.db.?);
    try std.testing.expectEqualStrings("k", show.outcome.hashCacheShow.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), show.outcome.hashCacheShow.base.yes);
    try std.testing.expectEqualStrings("c", show.outcome.hashCacheShow.base.cwd.?);
    try std.testing.expectEqual(@as(?bool, true), show.outcome.hashCacheShow.base.verbose);

    const clear = try parse(allocator, &.{ "hash-cache", "clear", "-k", "k", "-y", "-v" });
    try std.testing.expect(clear.outcome == .hashCacheClear);
    try std.testing.expect(clear.outcome.hashCacheClear.base.db == null);
    try std.testing.expectEqualStrings("k", clear.outcome.hashCacheClear.base.key.?);
    try std.testing.expectEqual(@as(?bool, true), clear.outcome.hashCacheClear.base.yes);
    try std.testing.expectEqual(@as(?bool, true), clear.outcome.hashCacheClear.base.verbose);

    const hashFile = try parse(allocator, &.{ "hash-cache", "hash-file", "f.jpg" });
    try std.testing.expectEqualStrings("f.jpg", hashFile.outcome.hashCacheHashFile);

    const add = try parse(allocator, &.{ "hash-cache", "add", "f.jpg", "--db", "d" });
    try std.testing.expectEqualStrings("f.jpg", add.outcome.hashCacheAdd.file);
    try std.testing.expectEqualStrings("d", add.outcome.hashCacheAdd.options.db);

    const set = try parse(allocator, &.{ "hash-cache", "set", "--db", "d", "p", "h", "12" });
    try std.testing.expectEqualStrings("p", set.outcome.hashCacheSet.key);
    try std.testing.expectEqualStrings("h", set.outcome.hashCacheSet.hash);
    try std.testing.expectEqualStrings("12", set.outcome.hashCacheSet.length);
    try std.testing.expectEqualStrings("d", set.outcome.hashCacheSet.options.db);

    const setSource = try parse(allocator, &.{ "hash-cache", "set-source", "s", "h", "7", "--db", "d" });
    try std.testing.expectEqualStrings("s", setSource.outcome.hashCacheSetSource.key);
    try std.testing.expectEqualStrings("h", setSource.outcome.hashCacheSetSource.hash);
    try std.testing.expectEqualStrings("7", setSource.outcome.hashCacheSetSource.length);
    try std.testing.expectEqualStrings("d", setSource.outcome.hashCacheSetSource.options.db);

    const get = try parse(allocator, &.{ "hash-cache", "get", "p", "--db", "d" });
    try std.testing.expectEqualStrings("p", get.outcome.hashCacheGet.key);
    try std.testing.expectEqualStrings("d", get.outcome.hashCacheGet.options.db);
    const getAssetId = try parse(allocator, &.{ "hash-cache", "get-asset-id", "p", "--db", "d" });
    try std.testing.expectEqualStrings("p", getAssetId.outcome.hashCacheGetAssetId.key);
    try std.testing.expectEqualStrings("d", getAssetId.outcome.hashCacheGetAssetId.options.db);
    const remove = try parse(allocator, &.{ "hash-cache", "remove", "p", "--db", "d" });
    try std.testing.expectEqualStrings("p", remove.outcome.hashCacheRemove.key);
    try std.testing.expectEqualStrings("d", remove.outcome.hashCacheRemove.options.db);

    try std.testing.expectEqualStrings("d", (try parse(allocator, &.{ "hash-cache", "list", "--db", "d" })).outcome.hashCacheList.db);
    try std.testing.expectEqualStrings("d", (try parse(allocator, &.{ "hash-cache", "count", "--db", "d" })).outcome.hashCacheCount.db);
    try std.testing.expectEqualStrings("d", (try parse(allocator, &.{ "hash-cache", "dir", "--db", "d" })).outcome.hashCacheDir.db);

    try expectCommanderError(allocator, &.{ "hash-cache", "bogus" }, "commander.unknownCommand", "error: unknown command 'bogus'\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "hash-file" }, "commander.missingArgument", "error: missing required argument 'file'\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "get", "--db", "d" }, "commander.missingArgument", "error: missing required argument 'path'\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "show", "extra" }, "commander.excessArguments", "error: too many arguments for 'show'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "list" }, "commander.missingMandatoryOptionValue", "error: required option '--db <path>' not specified\n");
    try expectCommanderError(allocator, &.{ "hash-cache", "set", "a", "b" }, "commander.missingMandatoryOptionValue", "error: required option '--db <path>' not specified\n");
}

//
// The help commander prints for the hash-cache command group (apps/cli/index.ts).
//
const hash_cache_help =
    \\Usage: psi hash-cache [options] [command]
    \\
    \\Inspect and manage a database's hash cache.
    \\
    \\Options:
    \\  -h, --help                                        display help for command
    \\
    \\Commands:
    \\  show [options]                                    Display information about a database's hash cache.
    \\  clear [options]                                   Clear a database's hash cache to force re-hashing of files.
    \\  hash-file <file>                                  Compute the SHA-256 hash of a file without touching the cache.
    \\  add [options] <file>                              Hash a file and record it in the hash cache.
    \\  set [options] <path> <hash> <length>              Record a hash in the hash cache against an arbitrary path.
    \\  set-source [options] <source-id> <hash> <length>  Record a hash in the hash cache against a photo library source id.
    \\  get [options] <path>                              Print the cached hash for a key. Exits 1 when it is not cached.
    \\  get-asset-id [options] <path>                     Print the asset id recorded against a key. Exits 1 when there is none.
    \\  remove [options] <path>                           Remove a key from the hash cache. Exits 1 when it was not cached.
    \\  list [options]                                    Print the key of every entry in the hash cache, one per line.
    \\  count [options]                                   Print how many entries the hash cache holds.
    \\  dir [options]                                     Print the directory holding a database's hash cache.
    \\  help [command]                                    display help for command
    \\
;

test "the hash-cache command group shows its help like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Without a subcommand the help goes to stderr, with --help and the help subcommand to stdout.
    const bare = try parse(allocator, &.{"hash-cache"});
    try std.testing.expect(bare.outcome == .failure);
    try std.testing.expectEqualStrings("commander.help", bare.outcome.failure.code);
    try std.testing.expectEqualStrings(hash_cache_help, bare.stderr);

    const help = try parse(allocator, &.{ "hash-cache", "--help" });
    try std.testing.expectEqualStrings("commander.helpDisplayed", help.outcome.failure.code);
    try std.testing.expectEqualStrings(hash_cache_help, help.stdout);

    const helpCommand = try parse(allocator, &.{ "hash-cache", "help" });
    try std.testing.expectEqualStrings(hash_cache_help, helpCommand.stdout);

    const helpGet = try parse(allocator, &.{ "hash-cache", "help", "get" });
    try std.testing.expectEqualStrings(
        \\Usage: psi hash-cache get [options] <path>
        \\
        \\Print the cached hash for a key. Exits 1 when it is not cached.
        \\
        \\Options:
        \\  --db <path>  The directory that contains the media file database
        \\  -h, --help   display help for command
        \\
    , helpGet.stdout);

    // The group is hidden from the program help.
    const programHelp = try parse(allocator, &.{"--help"});
    try std.testing.expect(std.mem.indexOf(u8, programHelp.stdout, "hash-cache") == null);
}

test "dbs command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect((try parse(allocator, &.{ "dbs", "list" })).outcome == .dbsList);
    try std.testing.expect((try parse(allocator, &.{ "d", "l" })).outcome == .dbsList);
    try std.testing.expect((try parse(allocator, &.{ "dbs", "ls" })).outcome == .dbsList);

    const add = try parse(allocator, &.{ "dbs", "add", "--yes", "--name", "n", "--description", "d", "--path", "/p", "--s3-cred", "s3", "--encryption-key", "enc", "--geocoding-key", "geo" });
    try std.testing.expect(add.outcome == .dbsAdd);
    try std.testing.expectEqual(@as(?bool, true), add.outcome.dbsAdd.yes);
    try std.testing.expectEqualStrings("n", add.outcome.dbsAdd.name.?);
    try std.testing.expectEqualStrings("d", add.outcome.dbsAdd.description.?);
    try std.testing.expectEqualStrings("/p", add.outcome.dbsAdd.path.?);
    try std.testing.expectEqualStrings("s3", add.outcome.dbsAdd.s3Cred.?);
    try std.testing.expectEqualStrings("enc", add.outcome.dbsAdd.encryptionKey.?);
    try std.testing.expectEqualStrings("geo", add.outcome.dbsAdd.geocodingKey.?);
    try std.testing.expectEqual(@as(?bool, false), add.state.notificationsQuiet);

    // The options have no defaults: an option not given is undefined.
    const addDefaults = try parse(allocator, &.{ "-q", "d", "add" });
    try std.testing.expect(addDefaults.outcome.dbsAdd.yes == null);
    try std.testing.expect(addDefaults.outcome.dbsAdd.name == null);
    try std.testing.expect(addDefaults.outcome.dbsAdd.s3Cred == null);
    try std.testing.expectEqual(@as(?bool, true), addDefaults.state.notificationsQuiet);

    const view = try parse(allocator, &.{ "d", "v", "--name", "x", "--path", "/p", "--yes" });
    try std.testing.expect(view.outcome == .dbsView);
    try std.testing.expectEqualStrings("x", view.outcome.dbsView.name.?);
    try std.testing.expectEqualStrings("/p", view.outcome.dbsView.path.?);
    try std.testing.expectEqual(@as(?bool, true), view.outcome.dbsView.yes);

    const edit = try parse(allocator, &.{ "dbs", "e", "--name", "a", "--new-name", "b", "--description", "d", "--path", "/p", "--s3-cred", "s3", "--encryption-key", "enc", "--geocoding-key", "geo", "--yes" });
    try std.testing.expect(edit.outcome == .dbsEdit);
    try std.testing.expectEqualStrings("a", edit.outcome.dbsEdit.name.?);
    try std.testing.expectEqualStrings("b", edit.outcome.dbsEdit.newName.?);
    try std.testing.expectEqualStrings("d", edit.outcome.dbsEdit.description.?);
    try std.testing.expectEqualStrings("/p", edit.outcome.dbsEdit.path.?);
    try std.testing.expectEqualStrings("s3", edit.outcome.dbsEdit.s3Cred.?);
    try std.testing.expectEqualStrings("enc", edit.outcome.dbsEdit.encryptionKey.?);
    try std.testing.expectEqualStrings("geo", edit.outcome.dbsEdit.geocodingKey.?);
    try std.testing.expectEqual(@as(?bool, true), edit.outcome.dbsEdit.yes);

    const remove = try parse(allocator, &.{ "dbs", "remove", "--path", "/p" });
    try std.testing.expect(remove.outcome == .dbsRemove);
    try std.testing.expectEqualStrings("/p", remove.outcome.dbsRemove.path.?);
    try std.testing.expect(remove.outcome.dbsRemove.name == null);
    try std.testing.expect(remove.outcome.dbsRemove.yes == null);

    const clear = try parse(allocator, &.{ "dbs", "clear", "--yes" });
    try std.testing.expect(clear.outcome == .dbsClear);
    try std.testing.expectEqual(@as(?bool, true), clear.outcome.dbsClear.yes);

    const send = try parse(allocator, &.{ "dbs", "send", "--name", "a", "--path", "/p", "--code", "1234", "--yes" });
    try std.testing.expect(send.outcome == .dbsSend);
    try std.testing.expectEqualStrings("a", send.outcome.dbsSend.name.?);
    try std.testing.expectEqualStrings("/p", send.outcome.dbsSend.path.?);
    try std.testing.expectEqualStrings("1234", send.outcome.dbsSend.code.?);
    try std.testing.expectEqual(@as(?bool, true), send.outcome.dbsSend.yes);

    const receive = try parse(allocator, &.{ "d", "receive", "--code", "1234", "--yes" });
    try std.testing.expect(receive.outcome == .dbsReceive);
    try std.testing.expectEqualStrings("1234", receive.outcome.dbsReceive.code.?);
    try std.testing.expectEqual(@as(?bool, true), receive.outcome.dbsReceive.yes);

    // Errors end the process with code 1, as commander does for a command without the program's exitOverride.
    try expectSecretsExit(allocator, &.{ "dbs", "bogus" }, 1, "error: unknown command 'bogus'\n");
    try expectSecretsExit(allocator, &.{ "dbs", "view", "--bogus" }, 1, "error: unknown option '--bogus'\n");
    try expectSecretsExit(allocator, &.{ "dbs", "edit", "--name" }, 1, "error: option '--name <name>' argument missing\n");
    try expectSecretsExit(allocator, &.{ "dbs", "list", "extra" }, 1, "error: too many arguments for 'list'. Expected 0 arguments but got 1.\n");
    try expectSecretsExit(allocator, &.{ "dbs", "--db", "x" }, 1, "error: unknown option '--db'\n");
}

test "the dbs group shows its help like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expectedHelp =
        \\Usage: psi dbs|d [options] [command]
        \\
        \\Manage the list of configured databases.
        \\
        \\Options:
        \\  -h, --help         display help for command
        \\
        \\Commands:
        \\  list|l             List all configured databases.
        \\  add [options]      Interactively add a new database to the list.
        \\  view|v [options]   Show all fields of a database entry.
        \\  edit|e [options]   Edit fields of a database entry.
        \\  remove [options]   Remove a database entry from the list.
        \\  clear [options]    Remove all database entries from the list.
        \\  send [options]     Send a database config (with secrets) to another device
        \\                     over the local network.
        \\  receive [options]  Receive a database config (with secrets) from another
        \\                     device over the local network.
        \\  help [command]     display help for command
        \\
    ;

    // --help writes the help to stdout and exits with 0.
    const help = try parse(allocator, &.{ "dbs", "--help" });
    try std.testing.expect(help.outcome == .processExit);
    try std.testing.expectEqual(@as(u8, 0), help.outcome.processExit);
    try std.testing.expectEqualStrings(expectedHelp, help.stdout);

    // With no subcommand the help goes to stderr and the exit code is 1.
    const bare = try parse(allocator, &.{"d"});
    try std.testing.expect(bare.outcome == .processExit);
    try std.testing.expectEqual(@as(u8, 1), bare.outcome.processExit);
    try std.testing.expectEqualStrings(expectedHelp, bare.stderr);

    const addHelp = try parse(allocator, &.{ "dbs", "add", "--help" });
    try std.testing.expectEqual(@as(u8, 0), addHelp.outcome.processExit);
    try std.testing.expectEqualStrings(
        \\Usage: psi dbs add [options]
        \\
        \\Interactively add a new database to the list.
        \\
        \\Options:
        \\  --yes                    Skip prompts
        \\  --name <name>            Database name
        \\  --description <desc>     Database description
        \\  --path <path>            Database path
        \\  --s3-cred <name>         S3 credential secret name
        \\  --encryption-key <name>  Encryption key secret name
        \\  --geocoding-key <name>   Geocoding API key secret name
        \\  -h, --help               display help for command
        \\
    , addHelp.stdout);
}

test "bug command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{ "bug", "--verbose", "--yes" });
    try std.testing.expect(parsed.outcome == .bug);
    try std.testing.expectEqual(@as(?bool, true), parsed.outcome.bug.verbose);
    try std.testing.expectEqual(@as(?bool, true), parsed.outcome.bug.yes);
    try std.testing.expect(parsed.outcome.bug.tools == null);

    // The preAction hook skips the notifications for bug.
    try std.testing.expectEqual(@as(?bool, null), parsed.state.notificationsQuiet);
    try std.testing.expectEqual(@as(?bool, null), (try parse(allocator, &.{ "-q", "bug" })).state.notificationsQuiet);

    const short = try parse(allocator, &.{ "bug", "-v", "-y" });
    try std.testing.expectEqual(@as(?bool, true), short.outcome.bug.verbose);
    try std.testing.expectEqual(@as(?bool, true), short.outcome.bug.yes);

    const yesOnly = try parse(allocator, &.{ "bug", "--yes" });
    try std.testing.expectEqual(@as(?bool, false), yesOnly.outcome.bug.verbose);
    try std.testing.expectEqual(@as(?bool, true), yesOnly.outcome.bug.yes);

    // Commander stores --no-browser as the browser option, so bugReportCommand's noBrowser is never set.
    const noBrowser = try parse(allocator, &.{ "bug", "--no-browser" });
    try std.testing.expect(noBrowser.outcome.bug.noBrowser == null);

    const defaults = try parse(allocator, &.{"bug"});
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.bug.verbose);
    try std.testing.expectEqual(@as(?bool, false), defaults.outcome.bug.yes);
    try std.testing.expect(defaults.outcome.bug.noBrowser == null);
    try expectCommanderError(allocator, &.{ "bug", "extra" }, "commander.excessArguments", "error: too many arguments for 'bug'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "bug", "--db", "d" }, "commander.unknownOption", "error: unknown option '--db'\n");
}

test "news command lines parse like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parse(allocator, &.{"news"});
    try std.testing.expect(parsed.outcome == .news);

    // The preAction hook skips the notifications for news.
    try std.testing.expectEqual(@as(?bool, null), parsed.state.notificationsQuiet);
    try std.testing.expect((try parse(allocator, &.{ "-q", "news" })).outcome == .news);
    try expectCommanderError(allocator, &.{ "news", "extra" }, "commander.excessArguments", "error: too many arguments for 'news'. Expected 0 arguments but got 1.\n");
    try expectCommanderError(allocator, &.{ "news", "--yes" }, "commander.unknownOption", "error: unknown option '--yes'\n");
}
