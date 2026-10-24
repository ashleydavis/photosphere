const std = @import("std");
const ziggy = @import("ziggy");
const events = @import("photosphere-core").events;
const support = @import("test-support.zig");

const TestApp = support.TestApp;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;

//
// Checks the last app event the core delivered. The reply to the message that ran the sender on the main thread comes after it.
//
fn expectEvent(app: *TestApp, expected: []const u8) !void {
    var index = app.native_app.count(std.testing.io, std.testing.allocator);
    while (index > 0) {
        index -= 1;
        const message = try app.native_app.messageAt(std.testing.io, std.testing.allocator, index);
        defer std.testing.allocator.free(message);
        if (std.mem.startsWith(u8, message, "{\"kind\":\"app\"")) {
            try std.testing.expectEqualStrings(expected, message);
            return;
        }
    }
    return error.NoAppEventDelivered;
}

//
// Runs a sender against the core on its main thread, where the core sends events, and waits for it.
//
fn sendOnMain(app: *TestApp, comptime send: fn (services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void) !void {
    const Call = struct {
        fn run(_: u8, services: HandlerServices, _: Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            try send(services, io, arena.allocator());
        }
    };
    try app.onMainThread(@as(u8, 0), Call.run);
}

test "database-opened carries the path" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendDatabaseOpened(services, io, arena, "fs:/photos/my \"best\" photos");
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"database-opened\",\"data\":\"fs:/photos/my \\\"best\\\" photos\"}}");
}

test "the events with no payload carry null" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendDatabaseClosed(services, io, arena);
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"database-closed\",\"data\":null}}");
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendDatabasesChanged(services, io, arena);
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"databases-changed\",\"data\":null}}");
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendSyncStarted(services, io, arena);
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"sync-started\",\"data\":null}}");
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendSyncCompleted(services, io, arena);
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"sync-completed\",\"data\":null}}");
}

test "theme-changed and navigate carry a string" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendThemeChanged(services, io, arena, std.json.Value{
                .string = "dark",
            });
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"theme-changed\",\"data\":\"dark\"}}");
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendNavigate(services, io, arena, "/gallery");
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"navigate\",\"data\":\"/gallery\"}}");
}

test "show-notification leaves out what the sender did not give" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendShowNotification(services, io, arena, .{
                .message = "Saved",
                .color = "success",
                .duration = 5000,
            });
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Saved\",\"color\":\"success\",\"duration\":5000}}}");
}

test "show-notification carries the link, the action and the news id of a news item" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendShowNotification(services, io, arena, .{
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
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"News\",\"color\":\"primary\",\"duration\":0,\"link\":{\"label\":\"Read\",\"url\":\"https://example.com/a\"},\"action\":{\"label\":\"Go\",\"url\":\"https://example.com/b\"},\"newsId\":\"news-1\"}}}");
}

test "update-available carries the latest version" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendUpdateAvailable(services, io, arena, "1.2.3");
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"update-available\",\"data\":{\"latestVersion\":\"1.2.3\"}}}");
}

test "platform-event carries the dev tools state" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendDevToolsState(services, io, arena, true);
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"platform-event\",\"data\":{\"type\":\"devtools-state\",\"open\":true}}}");
}

test "theme-changed carries the value written to the setting, whatever it is" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendThemeChanged(services, io, arena, std.json.Value{
                .bool = true,
            });
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"theme-changed\",\"data\":true}}");
}

test "show-notification carries a duration that is not a whole number as it is" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendOnMain(&app, struct {
        fn send(services: HandlerServices, io: std.Io, arena: std.mem.Allocator) anyerror!void {
            try events.sendShowNotification(services, io, arena, .{
                .message = "Hi",
                .color = "primary",
                .duration = 1.5,
            });
        }
    }.send);
    try expectEvent(&app, "{\"kind\":\"app\",\"data\":{\"type\":\"show-notification\",\"data\":{\"message\":\"Hi\",\"color\":\"primary\",\"duration\":1.5}}}");
}
