//
// Updates and news: the checks the main process makes once the page has loaded (checkForUpdate and checkForNews),
// and the channels the page uses to say it has shown the user an update or a news item
// (mark-update-shown and mark-news-shown). Each of the latter records the fact in the
// state file, so the same update or news item is not announced again at the next start.
//
// The channels are task types, because they write a file. The two checks are functions the main process calls from a task, because
// they wait on the network.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const events = @import("events.zig");
const test_mode = @import("test-mode.zig");
const main_state = @import("main-state.zig");
const config = @import("config-zig");

const Core = ziggy.core.Core;
const json = ziggy.json;
const TaskContext = ziggy.task_runner.TaskContext;
const logExceptions = @import("log-exceptions.zig").logExceptions;
const log = &utils.log.log;

//
// URL of the GitHub API endpoint that returns the latest non-prerelease release.
//
const LATEST_RELEASE_URL = "https://api.github.com/repos/ashleydavis/photosphere/releases/latest";

//
// URL of the news feed published in the Photosphere GitHub repo. Overridable via PHOTOSPHERE_NEWS_URL for the local demo script
// (apps/desktop/demo-news.sh) and for the smoke tests, which point it at a checked-in test yaml file.
//
const DEFAULT_NEWS_URL = "https://raw.githubusercontent.com/ashleydavis/photosphere/main/news.yaml";

//
// The body of checkForUpdate inside its try block: fetches the latest release and tells the page about it when it is newer than the
// running version and the user has not been told about it.
//
fn announceUpdate(core: *Core, arena: std.mem.Allocator, io: std.Io, running_version: []const u8) !void {
    const response = try node_api.fetch.fetch(arena, io, LATEST_RELEASE_URL);
    if (!response.ok) {
        return;
    }
    const data = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch |err| {
        return utils.errors.throwError("The latest release could not be read ({s}).", .{@errorName(err)});
    };
    if (data == .null) {
        return utils.errors.throwError("Cannot read properties of null (reading 'tag_name')", .{});
    }
    const tag_name = json.getString(data, "tag_name") orelse {
        return;
    };
    if (tag_name.len == 0) {
        return;
    }
    const latest_version = if (std.mem.startsWith(u8, tag_name, "v")) tag_name[1..] else tag_name;
    if (std.mem.eql(u8, latest_version, running_version)) {
        return;
    }
    const last_shown = try node_api.news_state.getLastShownUpdateVersion(arena, io);
    if (last_shown) |shown_version| {
        if (std.mem.eql(u8, shown_version, latest_version)) {
            return;
        }
    }
    try events.sendUpdateAvailable(core, arena, latest_version);
    log.info(try std.fmt.allocPrint(arena, "Showed update notification: v{s}", .{latest_version}));
}

//
// Compares the running build version against the latest GitHub release and, when a newer version is available that the user has not
// yet been notified about, sends an `update-available` event to the page (which renders the navbar pill and a primary-coloured sticky
// toast). The version is recorded in the state file's news section, `last_shown_update_version`, only when the user dismisses the
// toast (via the mark-update-shown channel), so closing the app without dismissing causes the notification to re-fire on the next
// startup.
//
// Skipped for `dev` and `nightly` builds (no real release to compare against) and in test mode unless explicitly opted in
// (PHOTOSPHERE_FORCE_UPDATE_CHECK). Network and parse failures are logged and skipped so update failures never block app startup.
//
// The core has no window to be missing, and an event sent while the page is not there is the shell's to hold or drop. The message
// of a reply that is not JSON is a sentence plus the parser's error name, and the message of a network failure is the Zig error name.
//
pub fn checkForUpdate(core: *Core, arena: std.mem.Allocator, io: std.Io, running_version: []const u8) !void {
    if (std.mem.eql(u8, running_version, "dev") or std.mem.indexOf(u8, running_version, "nightly") != null) {
        return;
    }
    if (test_mode.isTestMode() and test_mode.envValue("PHOTOSPHERE_FORCE_UPDATE_CHECK") == null) {
        return;
    }
    announceUpdate(core, arena, io, running_version) catch |err| {
        log.info(try std.fmt.allocPrint(arena, "Update check skipped: {s}", .{utils.errors.errorMessage(err)}));
    };
}

//
// The body of checkForNews inside its try block: fetches the feed and tells the page about the first item it has not shown.
//
fn announceNews(core: *Core, arena: std.mem.Allocator, io: std.Io, news_url: []const u8) !void {
    const items = try node_api.news_fetcher.fetchNews(arena, io, news_url);
    const shown_ids = try node_api.news_state.getShownNewsIds(arena, io);
    var next_item: ?node_api.news_fetcher.INewsItem = null;
    for (items) |item| {
        var already_shown = false;
        for (shown_ids) |shown_id| {
            if (std.mem.eql(u8, shown_id, item.id)) {
                already_shown = true;
                break;
            }
        }
        if (!already_shown) {
            next_item = item;
            break;
        }
    }
    const item = next_item orelse {
        return;
    };
    try events.sendShowNotification(core, arena, .{
        .message = item.message,
        .color = if (item.color) |color| (if (color.len > 0) color else "primary") else "primary",
        .duration = item.duration orelse 0,
        .link = if (item.link) |link| events.IShowNotificationLink{
            .label = link.label,
            .url = link.url,
        } else null,
        .action = if (item.action) |action| events.IShowNotificationLink{
            .label = action.label,
            .url = action.url,
        } else null,
        .newsId = item.id,
    });
    log.info(try std.fmt.allocPrint(arena, "Showed news notification: {s}", .{item.id}));
}

//
// Fetches the published news feed and, if there is an unseen item, sends the oldest one to the page as a toast notification. The item
// id is recorded in the state file's news section, `shown_news_ids`, only when the user dismisses the toast (via the mark-news-shown
// channel), so closing the app without dismissing causes the same item to re-fire next startup. Network errors and malformed feeds are
// logged and skipped so news failures never block app startup.
//
// In test mode the check is skipped unless PHOTOSPHERE_NEWS_URL points it at a test feed.
//
// The core has no window to be missing. The message of a network failure is the Zig error name.
//
pub fn checkForNews(core: *Core, arena: std.mem.Allocator, io: std.Io) !void {
    if (test_mode.isTestMode() and test_mode.envValue("PHOTOSPHERE_NEWS_URL") == null) {
        return;
    }
    const news_url = test_mode.envValue("PHOTOSPHERE_NEWS_URL") orelse DEFAULT_NEWS_URL;
    announceNews(core, arena, io, news_url) catch |err| {
        log.info(try std.fmt.allocPrint(arena, "News check skipped: {s}", .{utils.errors.errorMessage(err)}));
    };
}

//
// check-for-update: no payload. Runs checkForUpdate for the running build, as a task because the check waits on the network.
//
pub fn checkForUpdateTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const core = main_state.fromContext(context).core;
    try checkForUpdate(core, context.arena, context.io(), config.version);
    return try context.arena.dupe(u8, "null");
}

//
// check-for-news: no payload. Runs checkForNews, as a task because the check waits on the network.
//
pub fn checkForNewsTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try checkForNews(main_state.fromContext(context).core, context.arena, context.io());
    return try context.arena.dupe(u8, "null");
}

//
// mark-update-shown: the payload is the version of the update the user has been shown. Records it as the last one shown.
//
fn markUpdateShown(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The request needs the version of the update that was shown.", .{});
    }
    try node_api.news_state.setLastShownUpdateVersion(context.arena, context.io(), data.string);
    log.info(try std.fmt.allocPrint(context.arena, "Marked update notification as shown: v{s}", .{data.string}));
    return try context.arena.dupe(u8, "null");
}

//
// mark-news-shown: the payload is the id of the news item the user has been shown. Adds it to the ones shown.
//
fn markNewsShown(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The request needs the id of the news item that was shown.", .{});
    }
    try node_api.news_state.addShownNewsIds(context.arena, context.io(), &[_][]const u8{data.string});
    log.info(try std.fmt.allocPrint(context.arena, "Marked news notification as shown: {s}", .{data.string}));
    return try context.arena.dupe(u8, "null");
}

//
// The mark-update-shown channel's handler: markUpdateShown, with its errors logged.
//
pub const markUpdateShownHandler = logExceptions(markUpdateShown, "Error marking update notification as shown");

//
// The mark-news-shown channel's handler: markNewsShown, with its errors logged.
//
pub const markNewsShownHandler = logExceptions(markNewsShown, "Error marking news notification as shown");
