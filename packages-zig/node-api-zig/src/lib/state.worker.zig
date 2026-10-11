//
// Reads and writes state.yaml as a background task.
//
// The sibling of config.worker.zig and the same arrangement, for the same reason: the mobile WebView
// holds this state but cannot open a file, so its reads and writes run in the embedded worker over
// the storage layer.
//
// A write merges rather than replaces: it reads what is on disk, changes only what the caller sent,
// and writes the whole document back, so a sidebar collapsing does not take the news state with it.
//
// The file contents come from state-format.zig, the same module every reader converts through, so a
// file written here is readable by anything else that opens it by construction.
//
// (Zig: the values a write sends are the std.json.Value they arrive as. The task data and output are JSON values.)
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const state_format = @import("state-format.zig");
const app_state_format = @import("app-state-format.zig");
const errors = utils.errors;
const log = &utils.log.log;
const yaml = node_utils.yaml;
const FileStorage = storage_zig.file_storage.FileStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const INewsFeedItem = state_format.INewsFeedItem;
const INewsState = state_format.INewsState;
const IStateFile = state_format.IStateFile;
const defaultStateFile = state_format.defaultStateFile;
const parseStateYamlChecked = state_format.parseStateYamlChecked;
const stateFileToYaml = state_format.stateFileToYaml;
const IAppStateValue = app_state_format.IAppStateValue;
const appStateSettings = app_state_format.appStateSettings;
const appStateToYaml = app_state_format.appStateToYaml;
const setAppStateValue = app_state_format.setAppStateValue;
const yamlToAppState = app_state_format.yamlToAppState;

//
// Input for the read-state task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const IReadStateData = struct {
    // Sandbox-relative path of state.yaml.
    statePath: []const u8 = "",
};

//
// One state key the caller is changing.
//
// A missing `value` clears the key, which is what IConfig.clear means, and is not the same as the
// entry not being sent at all. The two have to be told apart because the entry crosses the bridge to
// the phone as JSON, where an undefined property simply disappears: a caller that meant "clear this"
// would arrive looking like a caller that meant nothing, so the key would be left as it was.
// (Zig: the value is the std.json.Value it arrives as. A null value clears the key, as an absent one does.)
//
pub const IWriteStateEntry = struct {
    // The flat key the interface uses.
    key: []const u8 = "",

    // What to store under it. Absent clears the key.
    value: ?IAppStateValue = null,
};

//
// The news part of a write, sent only when the caller is changing it.
// (Zig: the defaults let std.json parse data that leaves keys out.)
//
pub const IWriteStateNews = struct {
    // Ids of news items already shown, in the order they were first seen.
    shownNewsIds: []const []const u8 = &.{},

    // The release already announced to the user, or undefined when none has been.
    lastShownUpdateVersion: ?[]const u8 = null,

    // The feed the app has in hand.
    feed: []const INewsFeedItem = &.{},
};

//
// Input for the write-state task.
//
// Every part is optional, and a part that is absent is left as it is on disk.
//
pub const IWriteStateData = struct {
    // Sandbox-relative path of state.yaml.
    statePath: []const u8 = "",

    // The state keys being changed, each written where this file keeps it.
    entries: ?[]const IWriteStateEntry = null,

    // The news state, when that is what is being changed.
    news: ?IWriteStateNews = null,
};

//
// What reading the file gives back: the state, and the document it came from.
//
pub const IStateRead = struct {
    // The state, filled from the defaults for anything the file did not say.
    state: IStateFile,

    // The document as it was on disk, which is what the flat key/value view is built from. Undefined
    // when there is no file, or when it would not parse.
    document: ?std.json.Value = null,
};

//
// Reads the state file through storage, which is how it is reached on a device.
//
// A file that is not there, and one that will not parse, both come back as the defaults rather than
// throwing. Nothing in here is worth refusing to start over: losing it costs a collapsed sidebar and a
// remembered folder. The parse failure is logged so it is not silent.
//
pub fn readStateFromStorage(allocator: std.mem.Allocator, io: std.Io, statePath: []const u8) !IStateRead {
    var storage = FileStorage.init("fs:");
    const absent: IStateRead = .{
        .state = try defaultStateFile(allocator),
    };

    if (!try storage.fileExists(allocator, io, statePath)) {
        return absent;
    }

    const contents = try storage.read(allocator, io, statePath) orelse {
        return absent;
    };

    const parsed = try parseStateYamlChecked(allocator, contents);
    if (parsed.malformed) {
        log.@"error"(try std.fmt.allocPrint(allocator, "The state at \"{s}\" could not be parsed, using the defaults: {s}", .{ statePath, parsed.parseError orelse "" }));
    }
    return .{
        .state = parsed.state,
        .document = parsed.document,
    };
}

//
// Builds the JSON object of a cached news item, leaving out what it does not carry.
//
fn newsFeedItemToJson(allocator: std.mem.Allocator, item: INewsFeedItem) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "id", .{
        .string = item.id,
    });
    try object.put(allocator, "message", .{
        .string = item.message,
    });
    if (item.color) |color| {
        try object.put(allocator, "color", .{
            .string = color,
        });
    }
    if (item.duration) |duration| {
        try object.put(allocator, "duration", duration);
    }
    if (item.link) |link| {
        try object.put(allocator, "link", .{
            .string = link,
        });
    }
    return .{
        .object = object,
    };
}

//
// Builds the JSON object of the news state, as the read-state task returns it.
//
fn newsStateToJson(allocator: std.mem.Allocator, news: INewsState) !std.json.Value {
    var shownNewsIds = std.json.Array.init(allocator);
    for (news.shownNewsIds) |shownNewsId| {
        try shownNewsIds.append(.{
            .string = shownNewsId,
        });
    }

    var feed = std.json.Array.init(allocator);
    for (news.feed) |item| {
        try feed.append(try newsFeedItemToJson(allocator, item));
    }

    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "shownNewsIds", .{
        .array = shownNewsIds,
    });
    if (news.lastShownUpdateVersion) |lastShownUpdateVersion| {
        try object.put(allocator, "lastShownUpdateVersion", .{
            .string = lastShownUpdateVersion,
        });
    }
    try object.put(allocator, "feed", .{
        .array = feed,
    });
    return .{
        .object = object,
    };
}

//
// Handler for the read-state task.
// (Zig: the context is ignored.)
//
pub fn readStateHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when statePath is not a string.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IReadStateData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The read-state task data is not valid: statePath must be a string", .{});
    };
    if (data.statePath.len == 0) {
        return errors.throwError("statePath is required", .{});
    }

    const contents = try readStateFromStorage(allocator, io, data.statePath);

    var settingsObject: std.json.ObjectMap = .empty;
    var settings = try appStateSettings(allocator, try yamlToAppState(allocator, contents.document));
    var settingsIterator = settings.iterator();
    while (settingsIterator.next()) |entry| {
        try settingsObject.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "settings", .{
        .object = settingsObject,
    });
    try result.put(allocator, "news", try newsStateToJson(allocator, contents.state.news));
    return .{
        .object = result,
    };
}

//
// Handler for the write-state task.
//
// A read-modify-write: it reads what is on disk, replaces only what the caller sent, and writes the
// whole document back. Reading first is what keeps everything nobody touched.
// (Zig: the context is ignored. The task data is a JSON value holding IWriteStateData, and the
// handler returns null.)
//
pub fn writeStateHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when a field has the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IWriteStateData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The write-state task data is not valid: statePath must be a string, and entries and news must hold their parts", .{});
    };
    if (data.statePath.len == 0) {
        return errors.throwError("statePath is required", .{});
    }
    if (data.entries == null and data.news == null) {
        return errors.throwError("write-state was given no settings and no news section, so there is nothing to write.", .{});
    }

    var storage = FileStorage.init("fs:");
    const contents = try readStateFromStorage(allocator, io, data.statePath);
    var current = contents.state;

    if (data.news) |news| {
        current.news = .{
            .shownNewsIds = news.shownNewsIds,
            .lastShownUpdateVersion = news.lastShownUpdateVersion,
            .feed = news.feed,
        };
    }

    var document = try stateFileToYaml(allocator, current);

    // The keys the interface names go on last, through the flat view, which is the only thing that
    // knows which section each of them belongs in. It merges into the document rather than rebuilding
    // it, so it changes the keys it was given and leaves the rest of the file alone.
    if (data.entries) |entries| {
        var appState = try yamlToAppState(allocator, document);
        for (entries) |entry| {
            if (entry.key.len == 0) {
                return errors.throwError("write-state was given a setting with no key.", .{});
            }
            const value: ?IAppStateValue = if (entry.value) |entryValue| (if (entryValue == .null) null else entryValue) else null;
            try setAppStateValue(allocator, &appState, entry.key, value);
        }
        document = try appStateToYaml(allocator, appState, document);
    }

    const text = try yaml.dump(allocator, document);
    try storage.write(allocator, io, data.statePath, "application/yaml", text);
    return .null;
}
