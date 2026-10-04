const std = @import("std");
const pickers = @import("../lib/pickers.zig");

test "kinds are read from the numbers in ziggy.h" {
    try std.testing.expectEqual(pickers.PickKind.open_files, pickers.kindFromInt(0).?);
    try std.testing.expectEqual(pickers.PickKind.save_file, pickers.kindFromInt(1).?);
    try std.testing.expectEqual(pickers.PickKind.folder, pickers.kindFromInt(2).?);
    try std.testing.expectEqual(@as(?pickers.PickKind, null), pickers.kindFromInt(3));
    try std.testing.expectEqual(@as(?pickers.PickKind, null), pickers.kindFromInt(-1));
}

test "opening allows several files and folders do not" {
    const open = pickers.dialogOptions(.open_files, 0);
    try std.testing.expect(open & pickers.option_allow_multiselect != 0);
    try std.testing.expect(open & pickers.option_pick_folders == 0);
    try std.testing.expect(open & pickers.option_file_must_exist != 0);
    const folder = pickers.dialogOptions(.folder, 0);
    try std.testing.expect(folder & pickers.option_pick_folders != 0);
    try std.testing.expect(folder & pickers.option_allow_multiselect == 0);
}

test "saving asks before replacing and keeps the options the dialog had" {
    const save = pickers.dialogOptions(.save_file, 0x10000);
    try std.testing.expect(save & pickers.option_overwrite_prompt != 0);
    try std.testing.expect(save & pickers.option_allow_multiselect == 0);
    try std.testing.expect(save & 0x10000 != 0);
}

test "every kind has a title" {
    try std.testing.expectEqualStrings("Open", pickers.defaultTitle(.open_files));
    try std.testing.expectEqualStrings("Save", pickers.defaultTitle(.save_file));
    try std.testing.expectEqualStrings("Choose a folder", pickers.defaultTitle(.folder));
}

test "no paths is an empty array" {
    const json = try pickers.pathsJson(std.testing.allocator, &.{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[]", json);
}

test "paths are escaped" {
    const json = try pickers.pathsJson(std.testing.allocator, &.{ "C:\\a b\\c.txt", "D:\\say \"hi\".txt", "E:\\r\xc3\xa9sum\xc3\xa9" });
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("[\"C:\\\\a b\\\\c.txt\",\"D:\\\\say \\\"hi\\\".txt\",\"E:\\\\r\xc3\xa9sum\xc3\xa9\"]", json);
}

test "the option bits are the Windows FOS values" {
    try std.testing.expectEqual(@as(u32, 0x2), pickers.option_overwrite_prompt);
    try std.testing.expectEqual(@as(u32, 0x20), pickers.option_pick_folders);
    try std.testing.expectEqual(@as(u32, 0x40), pickers.option_force_file_system);
    try std.testing.expectEqual(@as(u32, 0x200), pickers.option_allow_multiselect);
    try std.testing.expectEqual(@as(u32, 0x800), pickers.option_path_must_exist);
    try std.testing.expectEqual(@as(u32, 0x1000), pickers.option_file_must_exist);
}
