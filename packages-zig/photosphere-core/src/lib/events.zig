//
// The events Photosphere's core sends to the page (including those of the
// worker pool it forwards from): database-opened, database-closed, databases-changed, sync-started, sync-completed,
// theme-changed, navigate, show-notification, update-available and platform-event. The page's side of each is in
// the platform provider of the page. task-event and task-completed are Ziggy's own events (system events, {"kind":"system","name",...}).
//
// Each function sends one event of the type of that name with the payload the page's handler takes, the payload being null
// where there is none. An event is an app event to Ziggy ({"kind":"app","data":...}), whose data is {"type", "data"}: the page's onEvent listener
// hands it to the page's listeners for that type.
//

const std = @import("std");
const ziggy = @import("ziggy");

const json = ziggy.json;

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
    duration: ?f64 = null,
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
// The type of the task event a task sends an event for the page in. The main thread sends the page the event it carries (see
// main-process.zig).
//
pub const APP_EVENT_TYPE = "app-event";

//
// Sends an event: the type and the payload, which is any value std.json can serialise. The sink is the handler services on the main
// thread, the native app's callbacks on a thread of the app's own, or a task's services. A task never reaches the main thread's state:
// it sends each event as a task event of type APP_EVENT_TYPE, and the main thread sends it on.
//
pub fn sendEvent(sink: anytype, io: std.Io, arena: std.mem.Allocator, event_type: []const u8, payload: anytype) !void {
    const data_json = try json.stringify(arena, .{
        .type = event_type,
        .data = payload,
    });
    if (@TypeOf(sink) == ziggy.task_runner.TaskServices) {
        try sink.sendEvent(io, arena, .{
            .type = APP_EVENT_TYPE,
            .event = json.Raw{
                .text = data_json,
            },
        });
        return;
    }
    try sink.sendEvent(io, arena, data_json);
}

//
// Tells the page a database was opened, by its path (`database-opened`).
//
pub fn sendDatabaseOpened(sink: anytype, io: std.Io, arena: std.mem.Allocator, database_path: []const u8) !void {
    try sendEvent(sink, io, arena, "database-opened", database_path);
}

//
// Tells the page to close the database that is open (`database-closed`).
//
pub fn sendDatabaseClosed(sink: anytype, io: std.Io, arena: std.mem.Allocator) !void {
    try sendEvent(sink, io, arena, "database-closed", null);
}

//
// Tells the page the list of databases changed, so it reads the list again (`databases-changed`).
//
pub fn sendDatabasesChanged(sink: anytype, io: std.Io, arena: std.mem.Allocator) !void {
    try sendEvent(sink, io, arena, "databases-changed", null);
}

//
// Tells the page a sync began (`sync-started`).
//
pub fn sendSyncStarted(sink: anytype, io: std.Io, arena: std.mem.Allocator) !void {
    try sendEvent(sink, io, arena, "sync-started", null);
}

//
// Tells the page a sync ended (`sync-completed`).
//
pub fn sendSyncCompleted(sink: anytype, io: std.Io, arena: std.mem.Allocator) !void {
    try sendEvent(sink, io, arena, "sync-completed", null);
}

//
// Tells the page the theme changed: the value written to the theme setting ("light", "dark" or "system"), or null when the setting was removed, which leaves the event without data as an undefined theme did (`theme-changed`).
//
pub fn sendThemeChanged(sink: anytype, io: std.Io, arena: std.mem.Allocator, theme: ?std.json.Value) !void {
    try sendEvent(sink, io, arena, "theme-changed", theme);
}

//
// Tells the page to go to a route, such as "/gallery" (`navigate`).
//
pub fn sendNavigate(sink: anytype, io: std.Io, arena: std.mem.Allocator, page: []const u8) !void {
    try sendEvent(sink, io, arena, "navigate", page);
}

//
// Asks the page to show a toast (`show-notification`).
//
pub fn sendShowNotification(sink: anytype, io: std.Io, arena: std.mem.Allocator, notification: IShowNotification) !void {
    try sendEvent(sink, io, arena, "show-notification", notification);
}

//
// Tells the page a newer release is out, by its version without the leading "v" (`update-available`).
//
pub fn sendUpdateAvailable(sink: anytype, io: std.Io, arena: std.mem.Allocator, latest_version: []const u8) !void {
    try sendEvent(sink, io, arena, "update-available", .{
        .latestVersion = latest_version,
    });
}

//
// Tells the page whether the developer tools are open: a platform-event of type "devtools-state".
//
pub fn sendDevToolsState(sink: anytype, io: std.Io, arena: std.mem.Allocator, open: bool) !void {
    try sendEvent(sink, io, arena, "platform-event", .{
        .type = "devtools-state",
        .open = open,
    });
}
