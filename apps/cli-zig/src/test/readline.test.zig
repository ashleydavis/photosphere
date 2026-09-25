const std = @import("std");
const cli = @import("cli-zig");
const readline = cli.readline;

//
// Parses the first keypress of the bytes (treating the end as the escape timeout).
//
fn parse(allocator: std.mem.Allocator, bytes: []const u8) !readline.Keypress {
    const result = (try readline.parseKeypress(allocator, bytes, true)).?;
    return result.keypress.?;
}

test "parseKeypress names keys like node's emitKeypressEvents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const up = try parse(allocator, "\x1b[A");
    try std.testing.expectEqualStrings("up", up.key.name.?);
    try std.testing.expect(up.char == null);

    const ctrl_c = try parse(allocator, "\x03");
    try std.testing.expectEqualStrings("c", ctrl_c.key.name.?);
    try std.testing.expect(ctrl_c.key.ctrl);
    try std.testing.expectEqualStrings("\x03", ctrl_c.char.?);

    const upper = try parse(allocator, "A");
    try std.testing.expectEqualStrings("a", upper.key.name.?);
    try std.testing.expect(upper.key.shift);

    try std.testing.expectEqualStrings("return", (try parse(allocator, "\r")).key.name.?);
    try std.testing.expectEqualStrings("enter", (try parse(allocator, "\n")).key.name.?);
    try std.testing.expectEqualStrings("backspace", (try parse(allocator, "\x7f")).key.name.?);
    try std.testing.expectEqualStrings("tab", (try parse(allocator, "\t")).key.name.?);
    try std.testing.expectEqualStrings("space", (try parse(allocator, " ")).key.name.?);
    try std.testing.expectEqualStrings("delete", (try parse(allocator, "\x1b[3~")).key.name.?);
    try std.testing.expectEqualStrings("home", (try parse(allocator, "\x1bOH")).key.name.?);

    const escape = try parse(allocator, "\x1b");
    try std.testing.expectEqualStrings("escape", escape.key.name.?);
    try std.testing.expect(escape.key.meta);

    const meta_b = try parse(allocator, "\x1bb");
    try std.testing.expectEqualStrings("b", meta_b.key.name.?);
    try std.testing.expect(meta_b.key.meta);
    try std.testing.expect(meta_b.char == null);

    const ctrl_right = try parse(allocator, "\x1b[1;5C");
    try std.testing.expectEqualStrings("right", ctrl_right.key.name.?);
    try std.testing.expect(ctrl_right.key.ctrl);

    const accented = try parse(allocator, "\u{e9}x");
    try std.testing.expect(accented.key.name == null);
    try std.testing.expectEqualStrings("\u{e9}", accented.char.?);
}

test "parseKeypress waits for the rest of an escape sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try readline.parseKeypress(arena.allocator(), "\x1b[", false) == null);
    try std.testing.expect(try readline.parseKeypress(arena.allocator(), "\x1b", false) == null);
}

test "the interface edits the line like readline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interface = readline.Interface.init(allocator);
    const keys = [_][]const u8{ "a", "b", "c", "\x1b[D", "X", "\x7f", "\x1b[H", "Z", "\x1b[F", "!" };
    for (keys) |key| {
        const keypress = try parse(allocator, key);
        try interface.ttyWrite(keypress.char, keypress.key);
    }
    try std.testing.expectEqualStrings("Zabc!", interface.line.items);
    try std.testing.expectEqual(@as(usize, 5), interface.cursor);

    const ctrl_w = try parse(allocator, "\x17");
    try interface.write("  word", null);
    try interface.ttyWrite(ctrl_w.char, ctrl_w.key);
    try std.testing.expectEqualStrings("Zabc!  ", interface.line.items);

    const ctrl_u = try parse(allocator, "\x15");
    try interface.ttyWrite(ctrl_u.char, ctrl_u.key);
    try std.testing.expectEqualStrings("", interface.line.items);

    try interface.write("text", null);
    const ret = try parse(allocator, "\r");
    try interface.ttyWrite(ret.char, ret.key);
    try std.testing.expectEqualStrings("", interface.line.items);
    try interface.write("more", null);
    const enter = try parse(allocator, "\n");
    try interface.ttyWrite(enter.char, enter.key);
    try std.testing.expectEqualStrings("more", interface.line.items);
    try interface.ttyWrite(enter.char, enter.key);
    try std.testing.expectEqualStrings("", interface.line.items);

    const escape = try parse(allocator, "\x1b");
    try interface.ttyWrite(escape.char, escape.key);
    try std.testing.expectEqualStrings("", interface.line.items);
}

test "PromptInput reads keypresses until the end of the input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("a\x1b[Bz\x1b");
    var input = readline.PromptInput.init(arena.allocator(), &reader, null);
    try std.testing.expect(!input.isTTY());
    input.setRawMode(true);
    try std.testing.expectEqualStrings("a", (try input.nextKeypress()).key.name.?);
    try std.testing.expectEqualStrings("down", (try input.nextKeypress()).key.name.?);
    try std.testing.expectEqualStrings("z", (try input.nextKeypress()).key.name.?);
    try std.testing.expectEqualStrings("escape", (try input.nextKeypress()).key.name.?);
    try std.testing.expectError(error.EndOfStream, input.nextKeypress());
}
