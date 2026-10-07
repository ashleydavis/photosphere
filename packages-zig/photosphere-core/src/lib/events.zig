//
// The events Photosphere's core sends to the page, from the `webContents.send` calls of apps/desktop/src/main.ts (and of the
// worker pool it forwards from): database-opened, database-closed, databases-changed, sync-started, sync-completed,
// theme-changed, navigate, show-notification, update-available and platform-event. The page's side of each is in
// apps/desktop-frontend/src/lib/platform-provider-electron.tsx. task-message and task-completed are Ziggy's own events.
//
// Each function sends one event, on the channel of that name with the payload the page's handler takes, the payload being null
// where Electron sent none. An event is a JSON message {"channel", "data"}.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const Core = ziggy.core.Core;
const json_util = ziggy.json_util;

//
// A labelled URL, for a link or an action button of a notification (IShowNotificationLink in the page).
//
pub const IShowNotificationLink = struct {
    // The visible label.
    label: []const u8,
    // The external URL opened when the link or the button is clicked.
    url: []const u8,
};

//
// What the page shows as a toast (IShowNotificationData in the page).
//
pub const IShowNotification = struct {
    // The message to display.
    message: []const u8,
    // The color variant: "primary", "success", "warning", "danger" or "neutral".
    color: []const u8,
    // The milliseconds before it is dismissed, where 0 means it is not. Left out when the sender has none.
    duration: ?i64 = null,
    // A folder to offer to open. Left out when there is none.
    folderPath: ?[]const u8 = null,
    // An inline link in the body of the toast. Left out when there is none.
    link: ?IShowNotificationLink = null,
    // A button for a link. Left out when there is none.
    action: ?IShowNotificationLink = null,
    // Marks the toast as a news item, so that dismissing it records it as shown. Left out when it is not one.
    newsId: ?[]const u8 = null,
};

//
// Sends an event: a message on the channel with the payload, which is any value std.json can serialise.
//
pub fn sendEvent(core: *Core, arena: std.mem.Allocator, channel: []const u8, payload: anytype) !void {
    const message = try json_util.stringify(arena, .{
        .channel = channel,
        .data = payload,
    });
    core.deliver(message);
}

//
// Tells the page a database was opened, by its path (`database-opened`).
//
pub fn sendDatabaseOpened(core: *Core, arena: std.mem.Allocator, database_path: []const u8) !void {
    try sendEvent(core, arena, "database-opened", database_path);
}

//
// Tells the page to close the database that is open (`database-closed`).
//
pub fn sendDatabaseClosed(core: *Core, arena: std.mem.Allocator) !void {
    try sendEvent(core, arena, "database-closed", null);
}

//
// Tells the page the list of databases changed, so it reads the list again (`databases-changed`).
//
pub fn sendDatabasesChanged(core: *Core, arena: std.mem.Allocator) !void {
    try sendEvent(core, arena, "databases-changed", null);
}

//
// Tells the page a sync began (`sync-started`).
//
pub fn sendSyncStarted(core: *Core, arena: std.mem.Allocator) !void {
    try sendEvent(core, arena, "sync-started", null);
}

//
// Tells the page a sync ended (`sync-completed`).
//
pub fn sendSyncCompleted(core: *Core, arena: std.mem.Allocator) !void {
    try sendEvent(core, arena, "sync-completed", null);
}

//
// Tells the page the theme changed: "light", "dark" or "system", or null when the setting was removed, which leaves the event without data as an undefined theme did (`theme-changed`).
//
pub fn sendThemeChanged(core: *Core, arena: std.mem.Allocator, theme: ?[]const u8) !void {
    try sendEvent(core, arena, "theme-changed", theme);
}

//
// Tells the page to go to a route, such as "/gallery" (`navigate`).
//
pub fn sendNavigate(core: *Core, arena: std.mem.Allocator, page: []const u8) !void {
    try sendEvent(core, arena, "navigate", page);
}

//
// Asks the page to show a toast (`show-notification`).
//
pub fn sendShowNotification(core: *Core, arena: std.mem.Allocator, notification: IShowNotification) !void {
    try sendEvent(core, arena, "show-notification", notification);
}

//
// Tells the page a newer release is out, by its version without the leading "v" (`update-available`).
//
pub fn sendUpdateAvailable(core: *Core, arena: std.mem.Allocator, latest_version: []const u8) !void {
    try sendEvent(core, arena, "update-available", .{
        .latestVersion = latest_version,
    });
}

//
// Tells the page whether the developer tools are open: a platform-event of type "devtools-state".
//
pub fn sendDevToolsState(core: *Core, arena: std.mem.Allocator, open: bool) !void {
    try sendEvent(core, arena, "platform-event", .{
        .type = "devtools-state",
        .open = open,
    });
}

//
// Tells the page a menu action was chosen: a platform-event of type "menu-action".
//
pub fn sendMenuAction(core: *Core, arena: std.mem.Allocator, action: []const u8) !void {
    try sendEvent(core, arena, "platform-event", .{
        .type = "menu-action",
        .action = action,
    });
}
