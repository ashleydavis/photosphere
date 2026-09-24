const std = @import("std");
const cli = @import("cli-zig");
const commander = cli.commander;
const Option = commander.Option;

test "Option.init splits short and long flags" {
    const key = Option.init(.{ .flags = "-k, --key <keyfile>", .description = "" });
    try std.testing.expectEqualStrings("-k", key.short.?);
    try std.testing.expectEqualStrings("--key", key.long.?);
    try std.testing.expect(key.required);
    try std.testing.expect(!key.optional);

    const destKey = Option.init(.{ .flags = "--dk, --dest-key <keyfile>", .description = "" });
    try std.testing.expectEqualStrings("--dk", destKey.short.?);
    try std.testing.expectEqualStrings("--dest-key", destKey.long.?);

    const tools = Option.init(.{ .flags = "--tools", .description = "", .defaultValue = false });
    try std.testing.expect(tools.short == null);
    try std.testing.expectEqualStrings("--tools", tools.long.?);
    try std.testing.expect(!tools.required);
    try std.testing.expectEqual(@as(?bool, false), tools.defaultValue);

    const optional = Option.init(.{ .flags = "-o [value]", .description = "" });
    try std.testing.expect(optional.optional);
    try std.testing.expect(optional.long == null);
    try std.testing.expectEqualStrings("o", optional.name());
}

test "Option.is and attributeName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const destKey = Option.init(.{ .flags = "--dk, --dest-key <keyfile>", .description = "" });
    try std.testing.expect(destKey.is("--dk"));
    try std.testing.expect(destKey.is("--dest-key"));
    try std.testing.expect(!destKey.is("--dest"));
    try std.testing.expectEqualStrings("destKey", try destKey.attributeName(arena.allocator()));
    const generateKey = Option.init(.{ .flags = "-g, --generate-key", .description = "" });
    try std.testing.expectEqualStrings("generateKey", try generateKey.attributeName(arena.allocator()));
}

test "parseOptions separates operands and unknown arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const options = [_]Option{
        Option.init(.{ .flags = "--db <path>", .description = "" }),
        Option.init(.{ .flags = "-y, --yes", .description = "" }),
    };
    var values: commander.OptionValues = .empty;
    const outcome = try commander.parseOptions(allocator, &options, &.{ "first", "--db", "x", "--unknown", "after", "-y" }, &values);
    const parsed = outcome.parsed;
    try std.testing.expectEqual(@as(usize, 1), parsed.operands.len);
    try std.testing.expectEqualStrings("first", parsed.operands[0]);
    try std.testing.expectEqual(@as(usize, 2), parsed.unknown.len);
    try std.testing.expectEqualStrings("--unknown", parsed.unknown[0]);
    try std.testing.expectEqualStrings("after", parsed.unknown[1]);
    try std.testing.expectEqualStrings("x", values.get("db").?.text);
    try std.testing.expect(values.get("yes").?.flag);
}

test "parseOptions reports a missing option value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const options = [_]Option{Option.init(.{ .flags = "--db <path>", .description = "" })};
    var values: commander.OptionValues = .empty;
    const outcome = try commander.parseOptions(arena.allocator(), &options, &.{"--db"}, &values);
    try std.testing.expectEqualStrings("error: option '--db <path>' argument missing", outcome.failure.message);
    try std.testing.expectEqualStrings("commander.optionMissingArgument", outcome.failure.code);
}

test "editDistance counts transpositions as one edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), try commander.editDistance(allocator, "full", "full"));
    try std.testing.expectEqual(@as(usize, 1), try commander.editDistance(allocator, "flul", "full"));
    try std.testing.expectEqual(@as(usize, 1), try commander.editDistance(allocator, "ful", "full"));
    try std.testing.expectEqual(@as(usize, 3), try commander.editDistance(allocator, "abc", "xyz"));
    try std.testing.expectEqual(@as(usize, 10), try commander.editDistance(allocator, "a", "abcdefghij"));
}

test "suggestSimilar suggests the closest candidates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("\n(Did you mean --full?)", try commander.suggestSimilar(allocator, "--flul", &.{ "--full", "--force", "--help" }));
    try std.testing.expectEqualStrings("\n(Did you mean one of --dest, --test?)", try commander.suggestSimilar(allocator, "--fest", &.{ "--test", "--dest", "--dest" }));
    try std.testing.expectEqualStrings("", try commander.suggestSimilar(allocator, "--zzzzzz", &.{ "--full", "--force" }));
    try std.testing.expectEqualStrings("", try commander.suggestSimilar(allocator, "--x", &.{}));
}

test "error messages match commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("error: unknown option '-x'", (try commander.unknownOptionError(allocator, "-x", &.{"--xx"})).message);
    try std.testing.expectEqualStrings("error: too many arguments for 'verify'. Expected 0 arguments but got 3.", (try commander.excessArgumentsError(allocator, "verify", 0, 3)).message);
    try std.testing.expectEqualStrings("error: too many arguments for 'x'. Expected 1 argument but got 2.", (try commander.excessArgumentsError(allocator, "x", 1, 2)).message);
}
