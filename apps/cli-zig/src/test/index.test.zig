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
        else if (std.mem.eql(u8, kind, "error") and std.mem.eql(u8, expected.get("level").?.string, "program")) {
            // The error is the program's own (no replicate or verify command was reached), so the command
            // line is handed to the TypeScript CLI, which reports it (checked against the real CLI by generate.ts).
            try std.testing.expect(outcome == .delegate);
            try std.testing.expectEqualStrings("", parsed.stderr);
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
            // The help of replicate and verify is rendered by the commander port (psi.json checks the text).
            try std.testing.expect(outcome == .failure);
            try std.testing.expectEqualStrings("commander.helpDisplayed", outcome.failure.code);
            try std.testing.expectEqual(@as(u8, 0), outcome.failure.exitCode);
            try std.testing.expect(std.mem.startsWith(u8, parsed.stdout, "Usage: psi "));
        }
        else {
            // --version is handed to the TypeScript CLI.
            try std.testing.expectEqualStrings("version", kind);
            try std.testing.expect(outcome == .delegate);
        }
    }
}

test "other commands and empty command lines are delegated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try parse(allocator, &.{})).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{"summary"})).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{ "init", "--db", "x" })).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{"--help"})).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{ "--db", "x", "replicate" })).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{ "help", "replicate" })).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{"replicate2"})).outcome == .delegate);
    try std.testing.expect((try parse(allocator, &.{ "rep", "--version" })).outcome == .delegate);
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
    const replicateDefinition = program.findCommand("rep").?;
    try std.testing.expectEqualStrings("replicate", replicateDefinition.getName());
    try std.testing.expectEqual(@as(usize, 13), replicateDefinition.options.items.len);
    const verifyDefinition = program.findCommand("ver").?;
    try std.testing.expectEqualStrings("verify", verifyDefinition.getName());
    try std.testing.expectEqual(@as(usize, 10), verifyDefinition.options.items.len);
    try std.testing.expectEqualStrings("Task timeout in milliseconds (default: 600000 = 10 minutes)", cli.timeoutOption.description);
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
