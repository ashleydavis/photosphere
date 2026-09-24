const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
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

test "command lines parse exactly like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "command-line.json");
    for (fixture.array.items) |commandCase| {
        const args = try helpers.stringArray(allocator, commandCase.object.get("args").?);
        const expected = commandCase.object.get("outcome").?.object;
        const kind = expected.get("kind").?.string;
        const outcome = try parseCommandLine(allocator, args);
        errdefer std.debug.print("args={f}\n", .{std.json.fmt(args, .{})});
        if (std.mem.eql(u8, kind, "replicate")) {
            const options = expected.get("options").?.object;
            try std.testing.expect(outcome == .replicate);
            const parsed = outcome.replicate;
            try expectBase(options, parsed.base);
            try expectText(options.get("dest"), parsed.dest);
            try expectText(options.get("destKey"), parsed.destKey);
            try expectFlag(options.get("generateKey"), parsed.generateKey);
            try expectText(options.get("path"), parsed.path);
            try expectFlag(options.get("force"), parsed.force);
            try expectFlag(options.get("partial"), parsed.partial);
            try expectFlag(options.get("full"), parsed.full);
        }
        else if (std.mem.eql(u8, kind, "verify")) {
            const options = expected.get("options").?.object;
            try std.testing.expect(outcome == .verify);
            const parsed = outcome.verify;
            try expectBase(options, parsed.base);
            try expectFlag(options.get("full"), parsed.full);
            try expectText(options.get("path"), parsed.path);
        }
        else if (std.mem.eql(u8, kind, "error")) {
            try std.testing.expect(outcome == .failure);
            const stderr = expected.get("stderr").?.string;
            try std.testing.expectEqualStrings(stderr[0 .. stderr.len - 1], outcome.failure.message);
            try std.testing.expectEqualStrings(expected.get("code").?.string, outcome.failure.code);
        }
        else {
            // Help and --version are handed to the TypeScript CLI.
            try std.testing.expect(outcome == .delegate);
        }
    }
}

test "other commands and empty command lines are delegated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(try parseCommandLine(allocator, &.{}) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{"summary"}) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{ "init", "--db", "x" }) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{"--help"}) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{ "--db", "x", "replicate" }) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{ "help", "replicate" }) == .delegate);
    try std.testing.expect(try parseCommandLine(allocator, &.{"replicate2"}) == .delegate);
}

test "the command declarations match index.ts" {
    try std.testing.expectEqualStrings("replicate", cli.replicateSpec.name);
    try std.testing.expectEqualStrings("rep", cli.replicateSpec.alias);
    try std.testing.expectEqual(@as(usize, 13), cli.replicateSpec.options.len);
    try std.testing.expectEqualStrings("verify", cli.verifySpec.name);
    try std.testing.expectEqualStrings("ver", cli.verifySpec.alias);
    try std.testing.expectEqual(@as(usize, 10), cli.verifySpec.options.len);
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
