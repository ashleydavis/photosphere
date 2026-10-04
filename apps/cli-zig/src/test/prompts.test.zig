const std = @import("std");
const cli = @import("cli-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const prompts = cli.prompts;
const PromptInput = prompts.PromptInput;

//
// The validation used by the fixture cases ("required").
//
fn requireValue(context: ?*anyopaque, value: ?[]const u8) ?[]const u8 {
    _ = context;
    const text = value orelse return "Value is required";
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        return "Value is required";
    }
    return null;
}

//
// The outcome of running a prompt in a test.
//
const PromptRun = struct {
    // True when the prompt was cancelled.
    cancelled: bool,

    // The submitted value as text (booleans as "true"/"false"), or null.
    value: ?[]const u8,
};

//
// Converts the select options of a fixture case.
//
fn selectOptions(allocator: std.mem.Allocator, value: std.json.Value) ![]const prompts.Option {
    const items = value.array.items;
    const options = try allocator.alloc(prompts.Option, items.len);
    for (items, 0..) |item, index| {
        options[index] = .{
            .value = item.object.get("value").?.string,
            .label = if (item.object.get("label")) |label| label.string else null,
            .hint = if (item.object.get("hint")) |hint| hint.string else null,
        };
    }
    return options;
}

//
// Gets an optional string field.
//
fn optionalString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return value.string;
}

//
// Runs the prompt of a fixture case with the keys as input, writing to output.
//
fn runCase(allocator: std.mem.Allocator, promptCase: std.json.Value, input: *PromptInput, output: *std.Io.Writer) !PromptRun {
    const io = std.testing.io;
    const kind = helpers.stringField(promptCase, "prompt");
    const options = promptCase.object.get("options").?.object;
    const common: prompts.CommonOptions = .{ .input = input, .output = output };
    const validate: ?prompts.ValidateFn = if (options.get("validate") != null) .{ .context = null, .function = requireValue } else null;
    if (std.mem.eql(u8, kind, "confirm")) {
        const result = try prompts.confirm(allocator, io, .{
            .common = common,
            .message = options.get("message").?.string,
            .active = optionalString(options, "active"),
            .inactive = optionalString(options, "inactive"),
            .initialValue = if (options.get("initialValue")) |initialValue| initialValue.bool else null,
        });
        if (prompts.isCancel(result)) {
            return .{ .cancelled = true, .value = null };
        }
        return .{ .cancelled = false, .value = if (result.value) "true" else "false" };
    }
    if (std.mem.eql(u8, kind, "select")) {
        const result = try prompts.select(allocator, io, .{
            .common = common,
            .message = options.get("message").?.string,
            .options = try selectOptions(allocator, options.get("options").?),
            .initialValue = optionalString(options, "initialValue"),
        });
        if (prompts.isCancel(result)) {
            return .{ .cancelled = true, .value = null };
        }
        return .{ .cancelled = false, .value = result.value };
    }
    if (std.mem.eql(u8, kind, "text")) {
        const result = try prompts.text(allocator, io, .{
            .common = common,
            .message = options.get("message").?.string,
            .placeholder = optionalString(options, "placeholder"),
            .defaultValue = optionalString(options, "defaultValue"),
            .initialValue = optionalString(options, "initialValue"),
            .validate = validate,
        });
        if (prompts.isCancel(result)) {
            return .{ .cancelled = true, .value = null };
        }
        return .{ .cancelled = false, .value = result.value };
    }
    if (std.mem.eql(u8, kind, "password")) {
        const result = try prompts.password(allocator, io, .{
            .common = common,
            .message = options.get("message").?.string,
            .validate = validate,
        });
        if (prompts.isCancel(result)) {
            return .{ .cancelled = true, .value = null };
        }
        return .{ .cancelled = false, .value = result.value.? };
    }
    if (std.mem.eql(u8, kind, "multiline")) {
        const result = try prompts.multiline(allocator, io, .{
            .common = common,
            .message = options.get("message").?.string,
        });
        if (prompts.isCancel(result)) {
            return .{ .cancelled = true, .value = null };
        }
        return .{ .cancelled = false, .value = result.value };
    }
    if (std.mem.eql(u8, kind, "outro")) {
        try prompts.outro(io, options.get("message").?.string, common);
        return .{ .cancelled = false, .value = null };
    }
    unreachable;
}

test "prompts render and answer exactly like the TypeScript prompts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    // The fixture was generated with stdout not a TTY (no process.stdout.columns), and the build runner gives
    // the tests a pipe for stdout.
    try std.testing.expect(cli.tty.columns(cli.tty.stdout_fd) == null);

    // The fixture was generated with TERM=xterm-256color, which also makes clack use unicode symbols on Windows.
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("TERM", "xterm-256color");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    const fixture = try helpers.loadFixture(allocator, "prompts.json");
    for (fixture.array.items, 0..) |promptCase, caseIndex| {
        const keys = try helpers.stringArray(allocator, promptCase.object.get("keys").?);
        const pending = helpers.boolField(promptCase, "pending");
        const input = try helpers.chunkedInput(allocator, keys);
        var output = std.Io.Writer.Allocating.init(allocator);
        errdefer std.debug.print("case {d}: {s} keys={f}\n", .{ caseIndex, helpers.stringField(promptCase, "prompt"), std.json.fmt(keys, .{}) });

        if (pending) {
            // TypeScript keeps waiting for more input; the test input ends instead.
            try std.testing.expectError(error.EndOfStream, runCase(allocator, promptCase, input, &output.writer));
            try std.testing.expectEqualStrings(helpers.stringField(promptCase, "output"), output.written());
            continue;
        }
        const run = try runCase(allocator, promptCase, input, &output.writer);
        try std.testing.expectEqualStrings(helpers.stringField(promptCase, "output"), output.written());
        try std.testing.expectEqual(helpers.boolField(promptCase, "cancelled"), run.cancelled);
        const expected_value = promptCase.object.get("value").?;
        switch (expected_value) {
            .null => try std.testing.expect(run.value == null),
            .bool => |flag| try std.testing.expectEqualStrings(if (flag) "true" else "false", run.value.?),
            .string => |text| try std.testing.expectEqualStrings(text, run.value.?),
            else => unreachable,
        }
    }
}

test "isCancel is true only for cancel" {
    const Result = prompts.PromptResult(bool);
    try std.testing.expect(prompts.isCancel(@as(Result, .cancel)));
    try std.testing.expect(!prompts.isCancel(@as(Result, .{ .value = true })));
}

test "keys left in the chunk that finished a prompt are lost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const input = try helpers.chunkedInput(allocator, &.{ "yn", "\x1b[B", "\r", "n", "a", "m", "e", "\r" });
    var output = std.Io.Writer.Allocating.init(allocator);
    const common: prompts.CommonOptions = .{ .input = input, .output = &output.writer };
    const first = try prompts.confirm(allocator, io, .{ .common = common, .message = "First?" });
    try std.testing.expect(first.value);
    const second = try prompts.select(allocator, io, .{ .common = common, .message = "Second?", .options = &.{ .{ .value = "a" }, .{ .value = "b" } } });
    try std.testing.expectEqualStrings("b", second.value);
    const third = try prompts.text(allocator, io, .{ .common = common, .message = "Third?" });
    try std.testing.expectEqualStrings("name", third.value);
}

test "the end of a test input is reported as EndOfStream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input = try helpers.chunkedInput(allocator, &.{});
    var output = std.Io.Writer.Allocating.init(allocator);
    try std.testing.expectError(error.EndOfStream, prompts.confirm(allocator, std.testing.io, .{ .common = .{ .input = input, .output = &output.writer }, .message = "Continue?" }));
}

// Ctrl+D as the first key of a prompt closes its readline interface, which pauses the input and leaves the prompt
// unresolved for good in TypeScript, so it ends the input as the end of a test input does.
test "a text prompt ends its input on ctrl-d with an empty line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The "x" and the return after the Ctrl+D would answer the prompt if it carried on reading.
    const input = try helpers.chunkedInput(allocator, &.{ "\x04", "x", "\r" });
    var output = std.Io.Writer.Allocating.init(allocator);
    try std.testing.expectError(error.EndOfStream, prompts.text(allocator, std.testing.io, .{ .common = .{ .input = input, .output = &output.writer }, .message = "Title?" }));
}

//
// What the TypeScript prompts write for a text prompt whose placeholder is empty, starts with a character of two
// UTF-8 bytes, or starts with a character outside the Basic Multilingual Plane (split into two surrogates, which
// are written as U+FFFD each), and for a select prompt whose hints are empty. Captured from the TypeScript prompts
// the way fixtures/generate.ts captures prompts.json.
//
const empty_and_non_ascii_cases =
    "[{\"prompt\":\"text\",\"options\":{\"message\":\"Name:\",\"placeholder\":\"\"},\"keys\":[\"a\",\"\\u" ++
    "007f\",\"\\r\"],\"pending\":false,\"cancelled\":false,\"value\":\"\",\"output\":\"\\u001b[?25l\\u001" ++
    "b[36m\\u25c6\\u001b[39m  Name:\\n\\u001b[36m \\u001b[39m  \\u001b[7m\\u001b[8m_\\u001b[28m\\u001b[27" ++
    "m\\n\\u001b[36m \\u001b[39m\\n\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[36m \\u001b" ++
    "[39m  a\\u2588\\u001b[2B\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  " ++
    "\\u001b[7m\\u001b[8m_\\u001b[28m\\u001b[27m\\u001b[2B\\u001b[999D\\u001b[3A\\u001b[J\\u001b[32m\\u25" ++
    "c7\\u001b[39m  Name:\\n\\u001b[90m \\u001b[39m\\n\\u001b[?25h\"},{\"prompt\":\"text\",\"options\":{" ++
    "\"message\":\"Name:\",\"placeholder\":\"\\u00e9-photos\"},\"keys\":[\"a\",\"\\u007f\",\"\\r\"],\"pen" ++
    "ding\":false,\"cancelled\":false,\"value\":\"\",\"output\":\"\\u001b[?25l\\u001b[36m\\u25c6\\u001b[3" ++
    "9m  Name:\\n\\u001b[36m \\u001b[39m  \\u001b[7m\\u00e9\\u001b[27m\\u001b[2m-photos\\u001b[22m\\n\\u0" ++
    "01b[36m \\u001b[39m\\n\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  a" ++
    "\\u2588\\u001b[2B\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  \\u001b" ++
    "[7m\\u00e9\\u001b[27m\\u001b[2m-photos\\u001b[22m\\u001b[2B\\u001b[999D\\u001b[3A\\u001b[J\\u001b[32" ++
    "m\\u25c7\\u001b[39m  Name:\\n\\u001b[90m \\u001b[39m\\n\\u001b[?25h\"},{\"prompt\":\"text\",\"option" ++
    "s\":{\"message\":\"Name:\",\"placeholder\":\"\\ud83d\\ude00 photos\"},\"keys\":[\"a\",\"\\u007f\",\"" ++
    "\\r\"],\"pending\":false,\"cancelled\":false,\"value\":\"\",\"output\":\"\\u001b[?25l\\u001b[36m\\u2" ++
    "5c6\\u001b[39m  Name:\\n\\u001b[36m \\u001b[39m  \\u001b[7m\\ufffd\\u001b[27m\\u001b[2m\\ufffd photo" ++
    "s\\u001b[22m\\n\\u001b[36m \\u001b[39m\\n\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[" ++
    "36m \\u001b[39m  a\\u2588\\u001b[2B\\u001b[999D\\u001b[3A\\u001b[1B\\u001b[2K\\u001b[G\\u001b[36m " ++
    "\\u001b[39m  \\u001b[7m\\ufffd\\u001b[27m\\u001b[2m\\ufffd photos\\u001b[22m\\u001b[2B\\u001b[999D" ++
    "\\u001b[3A\\u001b[J\\u001b[32m\\u25c7\\u001b[39m  Name:\\n\\u001b[90m \\u001b[39m\\n\\u001b[?25h\"}," ++
    "{\"prompt\":\"select\",\"options\":{\"message\":\"Pick one:\",\"options\":[{\"value\":\"first\",\"la" ++
    "bel\":\"First\",\"hint\":\"\"},{\"value\":\"second\",\"label\":\"Second\",\"hint\":\"\"}]},\"keys\":" ++
    "[\"\\u001b[B\",\"\\r\"],\"pending\":false,\"cancelled\":false,\"value\":\"second\",\"output\":\"\\u0" ++
    "01b[?25l\\u001b[90m \\u001b[39m\\n\\u001b[36m\\u25c6\\u001b[39m  Pick one:\\n\\u001b[36m \\u001b[39m" ++
    "  \\u001b[32m\\u25cf\\u001b[39m First\\n\\u001b[36m \\u001b[39m  \\u001b[2m\\u25cb\\u001b[22m \\u001" ++
    "b[2mSecond\\u001b[22m\\n\\u001b[36m \\u001b[39m\\n\\u001b[999D\\u001b[5A\\u001b[2B\\u001b[J\\u001b[3" ++
    "6m \\u001b[39m  \\u001b[2m\\u25cb\\u001b[22m \\u001b[2mFirst\\u001b[22m\\n\\u001b[36m \\u001b[39m  " ++
    "\\u001b[32m\\u25cf\\u001b[39m Second\\n\\u001b[36m \\u001b[39m\\n\\u001b[999D\\u001b[5A\\u001b[1B\\u" ++
    "001b[J\\u001b[32m\\u25c7\\u001b[39m  Pick one:\\n\\u001b[90m \\u001b[39m  \\u001b[2mSecond\\u001b[22" ++
    "m\\n\\u001b[?25h\"}]";

test "an empty placeholder or hint is left out, and a placeholder's first character is its first UTF-16 code unit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    try std.testing.expect(cli.tty.columns(cli.tty.stdout_fd) == null);
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("TERM", "xterm-256color");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    const cases = try std.json.parseFromSliceLeaky(std.json.Value, allocator, empty_and_non_ascii_cases, .{});
    for (cases.array.items) |promptCase| {
        const keys = try helpers.stringArray(allocator, promptCase.object.get("keys").?);
        const input = try helpers.chunkedInput(allocator, keys);
        var output = std.Io.Writer.Allocating.init(allocator);
        const run = try runCase(allocator, promptCase, input, &output.writer);
        try std.testing.expectEqualStrings(helpers.stringField(promptCase, "output"), output.written());
        try std.testing.expect(!run.cancelled);
        try std.testing.expectEqualStrings(helpers.stringField(promptCase, "value"), run.value.?);
    }
}

//
// What the TypeScript password prompt writes when a character outside the Basic Multilingual Plane is typed: it is
// two UTF-16 code units, so `userInput.replaceAll(/./g, mask)` masks it twice, and the cursor counts code units.
// Captured from the TypeScript prompt the way fixtures/generate.ts captures prompts.json.
//
const astral_password_cases =
    "[{\"prompt\":\"password\",\"options\":{\"message\":\"Secret:\"},\"keys\":[\"\\ud83d\\ude00\",\"a\"," ++
    "\"\\u001b[D\",\"\\r\"],\"pending\":false,\"cancelled\":false,\"value\":\"\\ud83d\\ude00a\",\"output" ++
    "\":\"\\u001b[?25l\\u001b[90m \\u001b[39m\\n\\u001b[36m\\u25c6\\u001b[39m  Secret:\\n\\u001b[36m \\u0" ++
    "01b[39m  \\u001b[7m\\u001b[8m_\\u001b[28m\\u001b[27m\\n\\u001b[36m \\u001b[39m\\n\\u001b[999D\\u001b" ++
    "[4A\\u001b[2B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  \\u25aa\\u25aa\\u001b[7m\\u001b[8m_\\u001b[" ++
    "28m\\u001b[27m\\u001b[2B\\u001b[999D\\u001b[4A\\u001b[2B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  " ++
    "\\u25aa\\u25aa\\u25aa\\u001b[7m\\u001b[8m_\\u001b[28m\\u001b[27m\\u001b[2B\\u001b[999D\\u001b[4A\\u0" ++
    "01b[2B\\u001b[2K\\u001b[G\\u001b[36m \\u001b[39m  \\u25aa\\u25aa\\u001b[7m\\u25aa\\u001b[27m\\u001b[" ++
    "2B\\u001b[999D\\u001b[4A\\u001b[1B\\u001b[J\\u001b[32m\\u25c7\\u001b[39m  Secret:\\n\\u001b[90m \\u0" ++
    "01b[39m  \\u001b[2m\\u25aa\\u25aa\\u25aa\\u001b[22m\\n\\u001b[?25h\"}]";

test "the password prompt masks each UTF-16 code unit, as replaceAll(/./g, mask) does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    try std.testing.expect(cli.tty.columns(cli.tty.stdout_fd) == null);
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("TERM", "xterm-256color");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    const cases = try std.json.parseFromSliceLeaky(std.json.Value, allocator, astral_password_cases, .{});
    for (cases.array.items) |promptCase| {
        const keys = try helpers.stringArray(allocator, promptCase.object.get("keys").?);
        const input = try helpers.chunkedInput(allocator, keys);
        var output = std.Io.Writer.Allocating.init(allocator);
        const run = try runCase(allocator, promptCase, input, &output.writer);
        try std.testing.expectEqualStrings(helpers.stringField(promptCase, "output"), output.written());
        try std.testing.expect(!run.cancelled);
        try std.testing.expectEqualStrings(helpers.stringField(promptCase, "value"), run.value.?);
    }
}
