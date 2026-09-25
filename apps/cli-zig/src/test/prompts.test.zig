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
    prompts.common.setColumnsForTesting(@as(?usize, null));
    defer prompts.common.setColumnsForTesting(null);

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
