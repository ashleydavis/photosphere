//
// The core: everything behind one handle. It owns the task runner, knows the channel handlers and the host callbacks,
// and routes every message from the page.
//

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const types = @import("types.zig");
const json_util = @import("json-util.zig");
const task_runner = @import("task-runner.zig");
const origin_check = @import("origin-check.zig");
const test_control = @import("test-control.zig");

const ZiggyConfig = types.ZiggyConfig;

//
// A handler for one channel. It returns the JSON text of its reply (allocated with the arena), or an error that becomes
// an error reply.
//
pub const ChannelHandler = *const fn (core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8;

//
// A channel and its handler.
//
pub const ChannelEntry = struct {
    // The channel name the page sends on.
    name: []const u8,
    // The function that answers it.
    handler: ChannelHandler,
};

//
// What an app adds to the core: its own channel handlers and task handlers.
//
pub const AppHandlers = struct {
    // The app's channels.
    channels: []const ChannelEntry,
    // The app's task types.
    tasks: []const task_runner.TaskHandlerEntry,
    // The app's request channels that are answered by a task, so that a slow answer, such as a dialog waiting for the user, does
    // not hold up the thread that handles page messages.
    task_channels: []const TaskChannelEntry,
    // The desktop menu as JSON: an array of menus, each {"label", "items"}, where an item is {"label", "action", "accelerator"}
    // or {"separator": true}, and may hold its own "items" for a submenu. "[]" for an app with no menu. Shells show it on
    // desktop only. See "Menus" in the architecture document.
    menu_json: []const u8,
};

//
// A request channel answered by a task: the page's request is queued as a task of this type, with the request's data as its input, and
// the task's result is the reply. A task that fails or is cancelled gives an error reply.
//
pub const TaskChannelEntry = struct {
    // The channel name the page sends on.
    name: []const u8,
    // The task type that answers it.
    task_type: []const u8,
};

//
// The channels that belong to Ziggy itself.
//
const ziggy_channels = [_]ChannelEntry{
    .{ .name = "get-platform", .handler = getPlatformHandler },
    .{ .name = "add-task", .handler = addTaskHandler },
    .{ .name = "cancel-tasks", .handler = cancelTasksHandler },
    .{ .name = "menu-action", .handler = menuActionHandler },
} ++ if (build_options.test_hooks) [_]ChannelEntry{
    .{ .name = "test-result", .handler = testResultHandler },
    .{ .name = "test-page-ready", .handler = testPageReadyHandler },
} else [_]ChannelEntry{};

//
// One running core.
//
pub const Core = struct {
    // Allocates everything the core owns.
    allocator: std.mem.Allocator,
    // The Io used for sleeping, waiting, files and sockets. It lives here so that its address is stable.
    threaded: std.Io.Threaded,
    // The channels that can be answered, Ziggy's and the app's.
    channels: []ChannelEntry,
    // The task types that can run.
    tasks: []const task_runner.TaskHandlerEntry,
    // The app's request channels that a task answers.
    task_channels: []const TaskChannelEntry,
    // The number of requests answered by a task so far, which names the next one's task.
    next_request_task: std.atomic.Value(u64),
    // The desktop menu as JSON, owned by the app.
    menu_json: []const u8,
    // The shell's configuration. The strings in it are copies owned by the core.
    config: ZiggyConfig,
    // The owned copy of the app's URL prefix.
    app_url_prefix: []u8,
    // The owned copy of the data directory.
    data_dir: []u8,
    // The task runner.
    runner: task_runner.TaskRunner,
    // The test control connection, only in a test hooks build and only when the shell is in test mode.
    control: ?*test_control.TestControl,

    //
    // Creates a core. The returned pointer is the handle.
    //
    pub fn create(allocator: std.mem.Allocator, config: ZiggyConfig, app: AppHandlers) !*Core {
        if (config.deliver == null) {
            return error.DeliverCallbackMissing;
        }
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        core.allocator = allocator;
        core.threaded = .init_single_threaded;
        const channels = try allocator.alloc(ChannelEntry, ziggy_channels.len + app.channels.len);
        errdefer allocator.free(channels);
        @memcpy(channels[0..ziggy_channels.len], &ziggy_channels);
        @memcpy(channels[ziggy_channels.len..], app.channels);
        core.channels = channels;
        core.tasks = app.tasks;
        core.task_channels = app.task_channels;
        core.next_request_task = .init(0);
        core.menu_json = app.menu_json;
        core.config = config;
        core.app_url_prefix = try allocator.dupe(u8, std.mem.span(config.app_url_prefix));
        errdefer allocator.free(core.app_url_prefix);
        core.data_dir = try allocator.dupe(u8, std.mem.span(config.data_dir));
        errdefer allocator.free(core.data_dir);
        core.control = null;
        try core.runner.start(allocator, core.threaded.io(), .{
            .user_data = core,
            .emit = emitFromRunner,
        }, app.tasks, .{
            .worker_threads = config.worker_threads,
            .max_concurrent_child_tasks = config.max_concurrent_child_tasks,
        }, config);
        errdefer core.runner.stop();
        if (build_options.test_hooks) {
            if (config.test_mode) {
                const control = try allocator.create(test_control.TestControl);
                errdefer allocator.destroy(control);
                try control.start(allocator, core.threaded.io(), config, emitFromRunner, core);
                core.control = control;
                core.runner.pick_override = .{
                    .user_data = control,
                    .take = test_control.TestControl.takePickAnswer,
                };
            }
        }
        return core;
    }

    //
    // Cancels every running task, waits for the workers to stop and releases everything.
    //
    pub fn destroy(self: *Core) void {
        if (self.control) |control| {
            control.stop();
            self.allocator.destroy(control);
        }
        self.runner.stop();
        self.allocator.free(self.channels);
        self.allocator.free(self.app_url_prefix);
        self.allocator.free(self.data_dir);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    //
    // Decides what to do with an address the web view is about to load.
    //
    pub fn checkUrl(self: *Core, url: []const u8) types.UrlDecision {
        return origin_check.checkUrl(self.app_url_prefix, url);
    }

    //
    // The Io the core's threads sleep and wait with.
    //
    pub fn io(self: *Core) std.Io {
        return self.threaded.io();
    }

    //
    // Sends a JSON message to the shell, and so to the page.
    //
    pub fn deliver(self: *Core, message: []const u8) void {
        const deliver_fn = self.config.deliver.?;
        deliver_fn(self.config.user_data, message.ptr, message.len);
    }

    //
    // Handles one message from the page: parses it, routes it by channel and replies when it carries an id.
    // A message that cannot be answered, because it has no usable id, is reported to the page as a core-error event
    // and never dropped silently.
    //
    pub fn postMessage(self: *Core, message: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, message, .{}) catch {
            self.reportError(arena, null, "InvalidMessage");
            return;
        };
        if (parsed != .object) {
            self.reportError(arena, null, "InvalidMessage");
            return;
        }
        const request_id: ?std.json.Value = parsed.object.get("id");
        const channel = json_util.getString(parsed, "channel") orelse {
            self.reportError(arena, request_id, "MissingChannel");
            return;
        };
        const data: std.json.Value = parsed.object.get("data") orelse .null;
        var handler: ?ChannelHandler = null;
        for (self.channels) |entry| {
            if (std.mem.eql(u8, entry.name, channel)) {
                handler = entry.handler;
                break;
            }
        }
        const found = handler orelse {
            for (self.task_channels) |entry| {
                if (std.mem.eql(u8, entry.name, channel)) {
                    self.answerWithTask(arena, entry, request_id, data);
                    return;
                }
            }
            self.reportError(arena, request_id, "UnknownChannel");
            return;
        };
        const reply_data = found(self, arena, data) catch |err| {
            self.reportError(arena, request_id, @errorName(err));
            return;
        };
        if (request_id) |id| {
            self.sendReply(arena, id, reply_data) catch |err| {
                self.reportError(arena, null, @errorName(err));
            };
        }
    }

    //
    // Answers a request with a task: queues the task and returns at once, and the reply is sent when the task ends. A request that
    // has no id has nothing to answer, so it is an error.
    //
    fn answerWithTask(self: *Core, arena: std.mem.Allocator, entry: TaskChannelEntry, request_id: ?std.json.Value, data: std.json.Value) void {
        const id = request_id orelse {
            self.reportError(arena, null, "RequestHasNoId");
            return;
        };
        const id_json = json_util.stringify(arena, id) catch @panic("out of memory building a request");
        const data_json = json_util.stringify(arena, data) catch @panic("out of memory building a request");
        const task_id = std.fmt.allocPrint(arena, "request-{d}", .{self.next_request_task.fetchAdd(1, .monotonic)}) catch @panic("out of memory building a request");
        self.runner.addTask(task_id, entry.task_type, "request", data_json, 0, id_json) catch |err| {
            self.reportError(arena, id, @errorName(err));
        };
    }

    fn sendReply(self: *Core, arena: std.mem.Allocator, id: std.json.Value, reply_data: []const u8) !void {
        const id_json = try json_util.stringify(arena, id);
        const reply = try std.fmt.allocPrint(arena, "{{\"id\":{s},\"ok\":true,\"data\":{s}}}", .{ id_json, reply_data });
        self.deliver(reply);
    }

    //
    // Answers a request with an error reply, or, when there is nothing to reply to, sends a core-error event.
    //
    fn reportError(self: *Core, arena: std.mem.Allocator, id: ?std.json.Value, error_name: []const u8) void {
        const name_json = json_util.stringify(arena, error_name) catch {
            @panic("out of memory building an error message");
        };
        if (id) |id_value| {
            const id_json = json_util.stringify(arena, id_value) catch {
                @panic("out of memory building an error message");
            };
            const reply = std.fmt.allocPrint(arena, "{{\"id\":{s},\"ok\":false,\"error\":{s}}}", .{ id_json, name_json }) catch {
                @panic("out of memory building an error message");
            };
            self.deliver(reply);
            return;
        }
        const event = std.fmt.allocPrint(arena, "{{\"channel\":\"core-error\",\"data\":{{\"error\":{s}}}}}", .{name_json}) catch {
            @panic("out of memory building an error message");
        };
        self.deliver(event);
    }
};

fn emitFromRunner(user_data: ?*anyopaque, message: []const u8) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.deliver(message);
}

fn getPlatformHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    _ = data;
    const platform_kind = switch (builtin.os.tag) {
        .ios => "mobile",
        else => if (builtin.abi.isAndroid()) "mobile" else "desktop",
    };
    return try json_util.stringify(arena, .{
        .platformKind = platform_kind,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
    });
}

fn addTaskHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const task_type = json_util.getString(data, "taskType") orelse {
        return error.MissingTaskType;
    };
    const task_id = json_util.getString(data, "taskId") orelse {
        return error.MissingTaskId;
    };
    const source = json_util.getString(data, "source") orelse {
        return error.MissingSource;
    };
    const priority: i64 = json_util.getInteger(data, "priority") orelse 0;
    const task_data: std.json.Value = if (data.object.get("data")) |value| value else .null;
    const data_json = try json_util.stringify(arena, task_data);
    try core.runner.addTask(task_id, task_type, source, data_json, @intCast(priority), null);
    return try arena.dupe(u8, "{}");
}

fn cancelTasksHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const source = json_util.getString(data, "source") orelse {
        return error.MissingSource;
    };
    core.runner.cancelSource(source);
    return try arena.dupe(u8, "{}");
}

fn testResultHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const control = core.control orelse {
        return error.TestControlNotRunning;
    };
    const request = json_util.getInteger(data, "requestId") orelse {
        return error.MissingRequestId;
    };
    const result: std.json.Value = if (data.object.get("result")) |value| value else .null;
    const result_json = try json_util.stringify(arena, result);
    try control.setAnswer(@intCast(request), result_json);
    return try arena.dupe(u8, "{}");
}

fn testPageReadyHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = data;
    const control = core.control orelse {
        return error.TestControlNotRunning;
    };
    control.markPageReady();
    return try arena.dupe(u8, "{}");
}

//
// A menu item was chosen, by the user or by a keyboard shortcut, and the shell passes its action on. The core hands it to the
// page as a menu-action event, which is how the page learns of every action the shell did not do itself.
//
fn menuActionHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const action = json_util.getString(data, "action") orelse {
        return error.MissingAction;
    };
    const action_json = try json_util.stringify(arena, action);
    const event = try std.fmt.allocPrint(arena, "{{\"channel\":\"menu-action\",\"data\":{{\"action\":{s}}}}}", .{action_json});
    core.deliver(event);
    return try arena.dupe(u8, "{}");
}
