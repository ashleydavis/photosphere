const std = @import("std");
const ziggy = @import("ziggy-core");
const menu = @import("../lib/menu.zig");
const handlers = @import("../lib/handlers.zig");

//
// The actions every shell performs itself. Every other action in the menu is the page's.
//
const shell_actions = [_][]const u8{ "quit", "close-window", "reload", "toggle-devtools", "toggle-fullscreen", "zoom-in", "zoom-out", "zoom-reset", "undo", "redo", "cut", "copy", "paste", "select-all" };

//
// The actions the page handles that are neither a navigation nor a theme.
//
const page_actions = [_][]const u8{ "new-database", "add-database", "open-database", "import-assets", "close-database", "open-configuration", "open-log-directory", "help", "report-bug" };

//
// The themes the page can be given.
//
const themes = [_][]const u8{ "light", "dark", "system" };

fn isShellAction(action: []const u8) bool {
    for (shell_actions) |shell_action| {
        if (std.mem.eql(u8, shell_action, action)) {
            return true;
        }
    }
    return false;
}

fn isPageAction(action: []const u8) bool {
    for (page_actions) |page_action| {
        if (std.mem.eql(u8, page_action, action)) {
            return true;
        }
    }
    if (std.mem.startsWith(u8, action, "navigate:/")) {
        return action.len > "navigate:/".len;
    }
    if (std.mem.startsWith(u8, action, "theme:")) {
        for (themes) |theme| {
            if (std.mem.eql(u8, theme, action["theme:".len..])) {
                return true;
            }
        }
    }
    return false;
}

fn checkItems(items: std.json.Value, seen_accelerators: *std.ArrayList([]const u8), seen_actions: *std.ArrayList([]const u8)) !void {
    for (items.array.items) |item| {
        if (item.object.get("separator") != null) {
            continue;
        }
        const label = ziggy.json_util.getString(item, "label") orelse return error.ItemHasNoLabel;
        try std.testing.expect(label.len > 0);
        if (item.object.get("items")) |children| {
            try checkItems(children, seen_accelerators, seen_actions);
            continue;
        }
        const action = ziggy.json_util.getString(item, "action") orelse return error.ItemHasNoAction;
        try std.testing.expect(isShellAction(action) or isPageAction(action));
        try seen_actions.append(std.testing.allocator, action);
        if (ziggy.json_util.getString(item, "accelerator")) |text| {
            _ = try ziggy.accelerator.parse(text);
            for (seen_accelerators.items) |seen| {
                try std.testing.expect(!std.mem.eql(u8, seen, text));
            }
            try seen_accelerators.append(std.testing.allocator, text);
        }
    }
}

test "the menu is valid JSON of menus with labelled items, each with a known action and a distinct shortcut that parses" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, menu.menu_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(parsed.value.array.items.len > 0);
    var seen_accelerators: std.ArrayList([]const u8) = .empty;
    defer seen_accelerators.deinit(std.testing.allocator);
    var seen_actions: std.ArrayList([]const u8) = .empty;
    defer seen_actions.deinit(std.testing.allocator);
    for (parsed.value.array.items) |menu_entry| {
        try std.testing.expect(ziggy.json_util.getString(menu_entry, "label") != null);
        try checkItems(menu_entry.object.get("items").?, &seen_accelerators, &seen_actions);
    }
}

test "every action the page handles is in the menu, and so are the developer tools and quit" {
    for (page_actions ++ [_][]const u8{ "toggle-devtools", "quit", "navigate:/stories", "navigate:/gallery", "theme:light", "theme:dark", "theme:system" }) |action| {
        const wanted = try std.fmt.allocPrint(std.testing.allocator, "\"action\": \"{s}\"", .{action});
        defer std.testing.allocator.free(wanted);
        try std.testing.expect(std.mem.indexOf(u8, menu.menu_json, wanted) != null);
    }
}


test "the app handlers carry the menu they are given and a page query" {
    const app = handlers.appHandlers(menu.menu_json, &[_]ziggy.ui_files.UiFile{});
    try std.testing.expectEqualStrings(menu.menu_json, app.menu_json);
    try std.testing.expect(app.page_query != null);
    try std.testing.expect(app.channels.len > 0);
    try std.testing.expect(app.tasks.len > 0);
    try std.testing.expect(app.task_channels.len > 0);
}
