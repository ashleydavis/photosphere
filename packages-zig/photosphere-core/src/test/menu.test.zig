const std = @import("std");
const ziggy = @import("ziggy");
const menu = @import("photosphere-core").menu;
const actions = @import("photosphere-core").actions;
const photosphere_app = @import("photosphere-app");

//
// The names of the items the page handles, which the core sends it as the app event {"type": "menu", "item": "<name>"}.
//
const page_items = [_][]const u8{
    "new-database",
    "add-database",
    "import-assets",
    "close-database",
    "navigate:/gallery",
    "navigate:/map",
    "navigate:/import",
    "navigate:/database-summary",
    "navigate:/news",
    "navigate:/about",
    "theme:light",
    "theme:dark",
    "theme:system",
    "navigate:/databases",
    "navigate:/secrets",
    "open-configuration",
    "navigate:/stories",
    "about",
    "help",
    "open-log-directory",
    "report-bug",
};

//
// The actions of the items the native app does itself.
//
const standard_actions = [_][]const u8{ "close-window", "quit", "undo", "redo", "cut", "copy", "paste", "select-all", "zoom-reset", "zoom-in", "zoom-out", "toggle-fullscreen", "reload", "toggle-devtools" };

test "every item the page handles is a .ui item of the menu; the menu has no other item the core runs but its actions" {
    const app = photosphere_app.app;
    for (page_items) |name| {
        try std.testing.expect(app.menu_targets.get(name).? == .ui);
    }
    try std.testing.expectEqual(page_items.len + actions.actions.len, app.menu_targets.keys().len);
}

test "the standard items are in the menu entries with their actions and the core does not run them" {
    const app = photosphere_app.app;
    for (standard_actions) |action| {
        try std.testing.expect(app.menu_targets.get(action) == null);
        var found = false;
        for (app.menu_entries) |entry| {
            if (entry.action) |entry_action| {
                if (std.mem.eql(u8, std.mem.span(entry_action), action)) {
                    found = true;
                }
            }
        }
        try std.testing.expect(found);
    }
}

test "the registered app carries the menu, a page query, an error describer, messages and task types" {
    const app = photosphere_app.app;
    try std.testing.expectEqual((comptime ziggy.menu.menuEntries(menu.menu, actions.actions)).len, app.menu_entries.len);
    try std.testing.expect(app.ui_query != null);
    try std.testing.expect(app.describe_error != null);
    try std.testing.expect(app.messages.len > 0);
    try std.testing.expect(app.tasks.len > 0);
}

test "Open Database is the Ziggy action open-database, which the core finds by its name" {
    const app = photosphere_app.app;
    try std.testing.expect(app.menu_targets.get("open-database").? == .action);
}

test "the menu entries show Open Database with its action's label, name and shortcut" {
    const app = photosphere_app.app;
    var found = false;
    for (app.menu_entries) |entry| {
        if (entry.action) |action| {
            if (std.mem.eql(u8, std.mem.span(action), "open-database")) {
                try std.testing.expectEqualStrings("Open Database...", std.mem.span(entry.label.?));
                try std.testing.expectEqualStrings("CmdOrCtrl+O", std.mem.span(entry.shortcut.?));
                found = true;
            }
        }
    }
    try std.testing.expect(found);
}
