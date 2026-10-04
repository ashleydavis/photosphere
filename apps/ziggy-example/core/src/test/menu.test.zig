const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");

// The actions every shell performs itself. Every other action in the menu is the app's and goes to the page.
const shell_actions = [_][]const u8{ "quit", "reload", "toggle-devtools", "toggle-fullscreen", "zoom-in", "zoom-out", "zoom-reset", "undo", "redo", "cut", "copy", "paste", "select-all" };

fn checkItems(items: std.json.Value, seen_accelerators: *std.ArrayList([]const u8)) !void {
    for (items.array.items) |item| {
        if (item.object.get("separator") != null) {
            continue;
        }
        const label = ziggy.json_util.getString(item, "label") orelse return error.ItemHasNoLabel;
        try std.testing.expect(label.len > 0);
        if (item.object.get("items")) |children| {
            try checkItems(children, seen_accelerators);
            continue;
        }
        try std.testing.expect(ziggy.json_util.getString(item, "action") != null);
        if (ziggy.json_util.getString(item, "accelerator")) |text| {
            _ = try ziggy.accelerator.parse(text);
            for (seen_accelerators.items) |seen| {
                try std.testing.expect(!std.mem.eql(u8, seen, text));
            }
            try seen_accelerators.append(std.testing.allocator, text);
        }
    }
}

test "the menu is valid JSON of menus with labelled items, each with an action and a distinct shortcut that parses" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, example.app.menu_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(parsed.value.array.items.len > 0);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (parsed.value.array.items) |menu| {
        try std.testing.expect(ziggy.json_util.getString(menu, "label") != null);
        try checkItems(menu.object.get("items").?, &seen);
    }
}

test "the menu has the actions the page handles and the developer tools item" {
    for ([_][]const u8{ "start-short", "start-long", "start-many", "cancel-long", "about", "toggle-devtools", "quit" }) |action| {
        const wanted = try std.fmt.allocPrint(std.testing.allocator, "\"action\": \"{s}\"", .{action});
        defer std.testing.allocator.free(wanted);
        try std.testing.expect(std.mem.indexOf(u8, example.app.menu_json, wanted) != null);
    }
}

test "the actions that are not the shells' own are the page's, and none is spelled like a shell action" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, example.app.menu_json, .{});
    defer parsed.deinit();
    var page_actions: usize = 0;
    for (parsed.value.array.items) |menu| {
        for (menu.object.get("items").?.array.items) |item| {
            const action = ziggy.json_util.getString(item, "action") orelse continue;
            var is_shell_action = false;
            for (shell_actions) |shell_action| {
                if (std.mem.eql(u8, shell_action, action)) {
                    is_shell_action = true;
                }
            }
            if (!is_shell_action) {
                page_actions += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 5), page_actions);
}
