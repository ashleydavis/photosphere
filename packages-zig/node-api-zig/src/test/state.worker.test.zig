//
// Tests for state.worker.zig.
//
// Tests for the mobile state.yaml handlers.
//
// These run against the real filesystem rather than a mock, for the same reason the config.yaml tests
// do: the point of the handlers is the bytes they put on disk. What matters is that a file written by
// one is read by the others, not which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device, so the tests run from a
// temporary directory standing in for that sandbox.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const mock_log = @import("mock-log.zig");
const test_task_context = @import("test-task-context.zig");
const errors = utils.errors;
const state_worker = node_api.state_worker;
const readStateHandler = state_worker.readStateHandler;
const writeStateHandler = state_worker.writeStateHandler;
const readStateFromStorage = state_worker.readStateFromStorage;
const TestTaskContext = test_task_context.TestTaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;

//
// The path the tests read and write, relative to the temporary sandbox below.
//
const STATE_PATH = "state.yaml";

//
// A temporary working directory standing in for the app's storage sandbox, the directory the test switches back to
// afterwards, and the task context the handlers take (they ignore it). Declare it, call init on it in place, and call
// deinit when the test is done.
//
const Sandbox = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The io the handlers use.
    io: std.Io,

    // The absolute path of the temporary directory.
    tempDir: []const u8,

    // The working directory before the test changed it.
    previousCwd: []const u8,

    // The uuids of the task context.
    uuidGenerator: TestUuidGenerator,

    // The task context the handlers take.
    taskContext: TestTaskContext,

    // Swallows what the code under test logs.
    mutedLog: mock_log.MutedLog,

    //
    // Makes the temporary directory and changes into it.
    //
    fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.io = std.testing.io;
        self.previousCwd = try std.process.currentPathAlloc(self.io, allocator);
        self.tempDir = try temp_dirs.makeTempDir(allocator, self.io, "state-worker");
        try std.process.setCurrentPath(self.io, self.tempDir);
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.taskContext.init(self.uuidGenerator.uuidGenerator());
        self.mutedLog = .{};
        self.mutedLog.install();
    }

    //
    // Changes back to the directory the test started in and removes the temporary one.
    //
    fn deinit(self: *Sandbox) void {
        self.mutedLog.uninstall();
        std.process.setCurrentPath(self.io, self.previousCwd) catch {
            @panic("The working directory could not be put back after a test.");
        };
        temp_dirs.removeTempDir(self.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Gets the allocator of the test.
    //
    fn arenaAllocator(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Writes the given text as the state file.
    //
    fn writeStateText(self: *Sandbox, text: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = STATE_PATH,
            .data = text,
        });
    }

    //
    // Reads the state file back as a parsed document.
    //
    fn readStateDocument(self: *Sandbox) !std.json.Value {
        const text = try std.Io.Dir.cwd().readFileAlloc(self.io, STATE_PATH, self.arenaAllocator(), .unlimited);
        return (try node_utils.yaml.load(self.arenaAllocator(), text));
    }

    //
    // Parses JSON text into a value.
    //
    fn json(self: *Sandbox, text: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arenaAllocator(), text, .{});
    }

    //
    // Runs the read-state handler for the state path and returns its result.
    //
    fn readState(self: *Sandbox, statePath: []const u8) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(self.arenaAllocator(), "statePath", .{
            .string = statePath,
        });
        return readStateHandler(self.arenaAllocator(), self.io, .{
            .object = object,
        }, self.taskContext.context.taskContext());
    }

    //
    // Runs the write-state handler with the JSON text as its data.
    //
    fn writeState(self: *Sandbox, dataJson: []const u8) !void {
        const result = try writeStateHandler(self.arenaAllocator(), self.io, try self.json(dataJson), self.taskContext.context.taskContext());
        try std.testing.expect(result == .null);
    }
};

//
// Gets the value at the dotted path of an object, or null when any step of it is missing.
//
fn at(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var steps = std.mem.splitScalar(u8, path, '.');
    while (steps.next()) |step| {
        if (current != .object) {
            return null;
        }
        current = current.object.get(step) orelse {
            return null;
        };
    }
    return current;
}

//
// Expects the value at the path to be this boolean.
//
fn expectBool(expected: bool, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected, found.bool);
}

//
// Expects the value at the path to be this string.
//
fn expectString(expected: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(expected, found.string);
}

//
// Expects nothing to be at the path.
//
fn expectMissing(value: std.json.Value, path: []const u8) !void {
    try std.testing.expect(at(value, path) == null);
}

//
// Expects the value at the path to be an array holding exactly these strings.
//
fn expectStrings(expected: []const []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].string);
    }
}

//
// Expects the value at the path to be an object with no keys.
//
fn expectEmptyObject(value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(usize, 0), found.object.count());
}

//
// Expects the value at the path to be an array holding exactly one news item with this id and message and no other keys.
//
fn expectOneFeedItem(id: []const u8, message: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(usize, 1), found.array.items.len);
    const item = found.array.items[0].object;
    try std.testing.expectEqual(@as(usize, 2), item.count());
    try std.testing.expectEqualStrings(id, item.get("id").?.string);
    try std.testing.expectEqualStrings(message, item.get("message").?.string);
}

//
// Expects the handler to fail with this message.
//
fn expectThrown(expectedMessage: []const u8, result: anytype) !void {
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

test "reading a sandbox with no state file yields nothing remembered rather than throwing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.readState(STATE_PATH);

    try expectEmptyObject(result, "settings");
    try expectStrings(&.{}, result, "news.shownNewsIds");
    try expectStrings(&.{}, result, "news.feed");
    try expectMissing(result, "news.lastShownUpdateVersion");
}

// Nothing in this file is worth refusing to start over. Losing it costs a collapsed sidebar and a remembered folder, and
// the app writes a fresh one as soon as anything is touched.
test "a corrupt state file reads as nothing remembered rather than throwing" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeStateText("gallery:\n  sort: name\n   this: [is not yaml");

    const result = try sandbox.readState(STATE_PATH);

    try expectEmptyObject(result, "settings");
}

test "a key the format declares is written into its own section and read back by name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\",\"value\":\"name\"}]}");

    try expectString("name", try sandbox.readStateDocument(), "gallery.sort");
    try expectString("name", try sandbox.readState(STATE_PATH), "settings.gallerySort");
}

test "a key the format places in the desktop section goes there rather than to the top level" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"lastFolder\",\"value\":\"/photos\"}]}");

    const document = try sandbox.readStateDocument();
    try expectString("/photos", document, "desktop.last_folder");
    try expectMissing(document, "last_folder");
    try expectString("/photos", try sandbox.readState(STATE_PATH), "settings.lastFolder");
}

// The interface builds these keys from a component's id, so they cannot be declared in advance. Before the ui section
// existed the desktop app accepted every one of them and then dropped it on the way to disk, so a collapsed sidebar never
// survived a restart.
test "a key the format does not name is kept in the ui section rather than dropped" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState(
        \\{"statePath":"state.yaml","entries":[
        \\{"key":"sidebar-collapsed-databases","value":true},
        \\{"key":"right-sidebar-collapsed-selection","value":false}]}
    );

    const document = try sandbox.readStateDocument();
    try expectBool(true, document, "ui.sidebar-collapsed-databases");
    try expectBool(false, document, "ui.right-sidebar-collapsed-selection");

    const settings = try sandbox.readState(STATE_PATH);
    try expectBool(true, settings, "settings.sidebar-collapsed-databases");
    try expectBool(false, settings, "settings.right-sidebar-collapsed-selection");
}

test "an entry with no value clears the key rather than leaving it as it was" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\",\"value\":\"name\"}]}");
    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\"}]}");

    try expectMissing(try sandbox.readStateDocument(), "gallery");
    try expectMissing(try sandbox.readState(STATE_PATH), "settings.gallerySort");
}

test "clearing the last ui key takes the section with it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"sidebar-collapsed-databases\",\"value\":true}]}");
    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"sidebar-collapsed-databases\"}]}");

    try expectMissing(try sandbox.readStateDocument(), "ui");
}

test "writing one key leaves every other one as it was" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState(
        \\{"statePath":"state.yaml","entries":[
        \\{"key":"lastFolder","value":"/photos"},
        \\{"key":"recentSearches","value":["beach"]}]}
    );

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\",\"value\":\"name\"}]}");

    const settings = try sandbox.readState(STATE_PATH);
    try expectString("/photos", settings, "settings.lastFolder");
    try expectStrings(&.{"beach"}, settings, "settings.recentSearches");
    try expectString("name", settings, "settings.gallerySort");
}

test "a written news state is read back" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try sandbox.writeState(
        \\{"statePath":"state.yaml","news":{
        \\"shownNewsIds":["release-1","survey-2"],
        \\"lastShownUpdateVersion":"0.9.1",
        \\"feed":[{"id":"release-1","message":"A new release"}]}}
    );

    const document = try sandbox.readStateDocument();
    try expectStrings(&.{ "release-1", "survey-2" }, document, "news.shown_news_ids");
    try expectString("0.9.1", document, "news.last_shown_update_version");
    try expectOneFeedItem("release-1", "A new release", document, "news.feed");

    const result = try sandbox.readState(STATE_PATH);
    try expectStrings(&.{ "release-1", "survey-2" }, result, "news.shownNewsIds");
    try expectString("0.9.1", result, "news.lastShownUpdateVersion");
    try expectOneFeedItem("release-1", "A new release", result, "news.feed");
}

// The id is how the app knows whether it has been shown and the message is the whole toast, so an item missing either
// would be announced forever or announced as an empty box.
test "a feed item with no id or no message is dropped rather than announced" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeStateText(
        \\news:
        \\  feed:
        \\    - id: good
        \\      message: A real item
        \\    - id: no-message
        \\    - message: no id
        \\
    );

    const result = try sandbox.readState(STATE_PATH);

    try expectOneFeedItem("good", "A real item", result, "news.feed");
}

test "a feed item naming a colour nobody defined loses the colour and keeps the item" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeStateText(
        \\news:
        \\  feed:
        \\    - id: good
        \\      message: A real item
        \\      color: neon
        \\
    );

    const result = try sandbox.readState(STATE_PATH);

    try expectOneFeedItem("good", "A real item", result, "news.feed");
}

test "a feed item's colour, duration and link are read back with it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeStateText(
        \\news:
        \\  feed:
        \\    - id: good
        \\      message: A real item
        \\      color: success
        \\      duration: 5000
        \\      link: https://example.com/release
        \\
    );

    const result = try sandbox.readState(STATE_PATH);

    const feed = at(result, "news.feed").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), feed.len);
    const item = feed[0].object;
    try std.testing.expectEqual(@as(usize, 5), item.count());
    try std.testing.expectEqualStrings("good", item.get("id").?.string);
    try std.testing.expectEqualStrings("A real item", item.get("message").?.string);
    try std.testing.expectEqualStrings("success", item.get("color").?.string);
    try std.testing.expectEqual(@as(i64, 5000), item.get("duration").?.integer);
    try std.testing.expectEqualStrings("https://example.com/release", item.get("link").?.string);
}

test "writing the news state leaves the interface's keys alone" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\",\"value\":\"name\"}]}");

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"news\":{\"shownNewsIds\":[\"release-1\"],\"feed\":[]}}");

    const result = try sandbox.readState(STATE_PATH);
    try expectString("name", result, "settings.gallerySort");
    try expectStrings(&.{"release-1"}, result, "news.shownNewsIds");
}

test "writing a key leaves the news state alone" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"news\":{\"shownNewsIds\":[\"release-1\"],\"feed\":[]}}");

    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"gallerySort\",\"value\":\"name\"}]}");

    const result = try sandbox.readState(STATE_PATH);
    try expectStrings(&.{"release-1"}, result, "news.shownNewsIds");
    try expectString("name", result, "settings.gallerySort");
}

test "a read with no path fails rather than reading nothing quietly" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("statePath is required", sandbox.readState(""));
}

test "a write with no path fails rather than writing nowhere quietly" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("statePath is required", writeStateHandler(sandbox.arenaAllocator(), sandbox.io, try sandbox.json("{\"statePath\":\"\"}"), sandbox.taskContext.context.taskContext()));
}

test "a write with nothing to write fails rather than doing nothing quietly" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown(
        "write-state was given no settings and no news section, so there is nothing to write.",
        writeStateHandler(sandbox.arenaAllocator(), sandbox.io, try sandbox.json("{\"statePath\":\"state.yaml\"}"), sandbox.taskContext.context.taskContext()),
    );
}

test "a key with no name fails rather than being written under an empty name" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown(
        "write-state was given a setting with no key.",
        writeStateHandler(sandbox.arenaAllocator(), sandbox.io, try sandbox.json("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"\",\"value\":true}]}"), sandbox.taskContext.context.taskContext()),
    );
}

test "the file on disk is readable by the plain reader, so a phone and a desktop agree on it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeState("{\"statePath\":\"state.yaml\",\"entries\":[{\"key\":\"lastFolder\",\"value\":\"/photos\"}]}");

    const contents = try readStateFromStorage(sandbox.arenaAllocator(), sandbox.io, STATE_PATH);

    try std.testing.expectEqualStrings("/photos", contents.state.desktop.lastFolder.?);
}
