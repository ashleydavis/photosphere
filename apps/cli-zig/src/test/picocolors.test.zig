const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const pc = cli.picocolors;

//
// Looks up a style by its picocolors name.
//
fn styleNamed(name: []const u8) pc.Style {
    inline for (@typeInfo(pc.styles).@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) {
            return @field(pc.styles, decl.name);
        }
    }
    unreachable;
}

test "every style matches picocolors output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "picocolors.json");
    const colors = pc.createColors(true);
    for (fixture.object.get("styleCases").?.array.items) |styleCase| {
        const output = try colors.apply(allocator, styleNamed(helpers.stringField(styleCase, "style")), helpers.stringField(styleCase, "input"));
        try std.testing.expectEqualStrings(helpers.stringField(styleCase, "output"), output);
    }
}

test "disabled colors return the input unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const colors = pc.createColors(false);
    try std.testing.expectEqualStrings("text", try colors.apply(arena.allocator(), pc.styles.red, "text"));
}

test "color detection matches picocolors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "picocolors.json");
    for (fixture.object.get("detectionCases").?.array.items) |detectionCase| {
        const env = detectionCase.object.get("env").?.object;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, "psi");
        try argv.appendSlice(allocator, try helpers.stringArray(allocator, detectionCase.object.get("argv").?));
        const environment: pc.IColorEnvironment = .{
            .NO_COLOR = if (env.get("NO_COLOR")) |value| value.string else null,
            .FORCE_COLOR = if (env.get("FORCE_COLOR")) |value| value.string else null,
            .TERM = if (env.get("TERM")) |value| value.string else null,
            .CI = if (env.get("CI")) |value| value.string else null,
            .argv = argv.items,
            .isWin32 = false,
            .stdoutIsTTY = helpers.boolField(detectionCase, "stdoutIsTTY"),
        };
        try std.testing.expectEqual(helpers.boolField(detectionCase, "isColorSupported"), pc.detectColorSupport(environment));
    }
}

test "a TTY enables colors unless TERM is dumb" {
    const base: pc.IColorEnvironment = .{ .NO_COLOR = null, .FORCE_COLOR = null, .TERM = "xterm", .CI = null, .argv = &.{}, .isWin32 = false, .stdoutIsTTY = true };
    try std.testing.expect(pc.detectColorSupport(base));
    var dumb = base;
    dumb.TERM = "dumb";
    try std.testing.expect(!pc.detectColorSupport(dumb));
    var no_color = base;
    no_color.NO_COLOR = "1";
    try std.testing.expect(!pc.detectColorSupport(no_color));
    var windows = base;
    windows.stdoutIsTTY = false;
    windows.isWin32 = true;
    try std.testing.expect(pc.detectColorSupport(windows));
}

test "the override forces the default colors on and off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    pc.setColorSupportOverride(true);
    defer pc.setColorSupportOverride(null);
    try std.testing.expect(pc.isColorSupported());
    try std.testing.expectEqualStrings("\x1b[36mx\x1b[39m", try pc.cyan(allocator, "x"));
    try std.testing.expectEqualStrings("\x1b[1m\x1b[32mx\x1b[39m\x1b[22m", try pc.bold(allocator, try pc.green(allocator, "x")));
    pc.setColorSupportOverride(false);
    try std.testing.expectEqualStrings("x", try pc.yellow(allocator, "x"));
    try std.testing.expectEqualStrings("x", try pc.gray(allocator, "x"));
}
