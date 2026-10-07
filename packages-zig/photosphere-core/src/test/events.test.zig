const std = @import("std");
const events = @import("../lib/events.zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// Runs the sender against a core and checks the one message it delivered.
//
fn expectEvent(app: *TestApp, expected: []const u8) !void {
    const message = try app.shell.messageAt(std.testing.allocator, app.shell.count() - 1);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(expected, message);
}

test "database-opened carries the path" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendDatabaseOpened(app.core, arena.allocator(), "fs:/photos/my \"best\" photos");
    try expectEvent(&app, "{\"channel\":\"database-opened\",\"data\":\"fs:/photos/my \\\"best\\\" photos\"}");
}

test "the events with no payload carry null" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendDatabaseClosed(app.core, arena.allocator());
    try expectEvent(&app, "{\"channel\":\"database-closed\",\"data\":null}");
    try events.sendDatabasesChanged(app.core, arena.allocator());
    try expectEvent(&app, "{\"channel\":\"databases-changed\",\"data\":null}");
    try events.sendSyncStarted(app.core, arena.allocator());
    try expectEvent(&app, "{\"channel\":\"sync-started\",\"data\":null}");
    try events.sendSyncCompleted(app.core, arena.allocator());
    try expectEvent(&app, "{\"channel\":\"sync-completed\",\"data\":null}");
}

test "theme-changed and navigate carry a string" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendThemeChanged(app.core, arena.allocator(), "dark");
    try expectEvent(&app, "{\"channel\":\"theme-changed\",\"data\":\"dark\"}");
    try events.sendNavigate(app.core, arena.allocator(), "/gallery");
    try expectEvent(&app, "{\"channel\":\"navigate\",\"data\":\"/gallery\"}");
}

test "show-notification leaves out what the sender did not give" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendShowNotification(app.core, arena.allocator(), .{
        .message = "Saved",
        .color = "success",
        .duration = 5000,
    });
    try expectEvent(&app, "{\"channel\":\"show-notification\",\"data\":{\"message\":\"Saved\",\"color\":\"success\",\"duration\":5000}}");
}

test "show-notification carries the link, the action and the news id of a news item" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendShowNotification(app.core, arena.allocator(), .{
        .message = "News",
        .color = "primary",
        .duration = 0,
        .link = .{
            .label = "Read",
            .url = "https://example.com/a",
        },
        .action = .{
            .label = "Go",
            .url = "https://example.com/b",
        },
        .newsId = "news-1",
    });
    try expectEvent(&app, "{\"channel\":\"show-notification\",\"data\":{\"message\":\"News\",\"color\":\"primary\",\"duration\":0,\"link\":{\"label\":\"Read\",\"url\":\"https://example.com/a\"},\"action\":{\"label\":\"Go\",\"url\":\"https://example.com/b\"},\"newsId\":\"news-1\"}}");
}

test "update-available carries the latest version" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendUpdateAvailable(app.core, arena.allocator(), "1.2.3");
    try expectEvent(&app, "{\"channel\":\"update-available\",\"data\":{\"latestVersion\":\"1.2.3\"}}");
}

test "platform-event carries the dev tools state and the menu action" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try events.sendDevToolsState(app.core, arena.allocator(), true);
    try expectEvent(&app, "{\"channel\":\"platform-event\",\"data\":{\"type\":\"devtools-state\",\"open\":true}}");
    try events.sendMenuAction(app.core, arena.allocator(), "new-database");
    try expectEvent(&app, "{\"channel\":\"platform-event\",\"data\":{\"type\":\"menu-action\",\"action\":\"new-database\"}}");
}
