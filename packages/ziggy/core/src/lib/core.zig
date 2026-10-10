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
const queue_backend = @import("queue-backend.zig");
const task_queue = @import("task-queue-zig");
const origin_check = @import("origin-check.zig");
const test_control = @import("test-control.zig");
const ui_files = @import("ui-files.zig");
const dropped_files = @import("dropped-files.zig");

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
    // The files of the app's bundled page, embedded in the app's library, for a shell that serves the page by asking the core
    // for each file (the MacOS, iOS and Android shells). Empty for an app whose shell embeds the page itself.
    ui_files: []const ui_files.UiFile,
    // Turns the error a channel handler returned into the text of the error reply, for an app whose code reports the reason for
    // a failure somewhere other than the error's name (a Zig error carries no message). It returns null when it has nothing to
    // say about the error, and the reply then carries the error's name. It is called on the thread that handled the message,
    // straight after the handler failed, and the text is used before the call returns.
    describe_error: ?ErrorDescriber = null,
    // Where the app keeps what it remembers while it runs, which the core holds and hands back to the app's handlers through
    // `Core.app_state`. Null for an app that keeps nothing.
    state: ?AppState = null,
    // Called when a task has ended, after the page has been told, from the thread that ran it, with no lock held. The values are
    // valid only during the call.
    on_task_end: ?*const fn (core: *Core, end: types.TaskEnd) void = null,
    // Called when a task has sent a message, after the page has been told, from the thread that sent it, with no lock held. The values
    // are valid only during the call.
    on_task_message: ?*const fn (core: *Core, sent: types.TaskSentMessage) void = null,
    // Gives the query text the shell appends to the address of the page, after the question mark, so the page's first render already
    // holds what the app tells it at start-up. Null for an app whose page needs no query. See `PageQuery`.
    page_query: ?PageQuery = null,
};

//
// An app's function for the query of the page's address. The core calls it when the shell asks (the shell asks once the core exists,
// before it loads the page), with whether the test mode switch is on, which the app says in the query however it likes. It returns
// the text after the question mark, such as `restApiUrl=...&testMode=1`, or an empty string for no query, allocated with the
// allocator given, which is an arena that is released when the call returns. Ziggy passes the text through unread, so no shell
// composes a query and Ziggy names none of its parts.
//
pub const PageQuery = *const fn (core: *Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8;

//
// The state an app keeps in the core. The core makes it when it is created, after the task runner is running. When the core is
// destroyed it stops the state first, before the task runner stops, so what the state owns that runs by itself (a timer thread, say)
// can end while tasks can still be queued, and destroys the state last, after the task runner has stopped, so nothing a running task
// reads (the state itself, a log file) is gone while a task can still run.
//
pub const AppState = struct {
    // Makes the app's state. The core's `app_state` is null until this returns.
    create: *const fn (core: *Core) anyerror!*anyopaque,
    // Stops what the state owns that runs by itself. The state stays valid, because tasks that are still running read it.
    stop: *const fn (core: *Core, state: *anyopaque) void,
    // Releases the state `create` made, after the task runner has stopped and no task can read it.
    destroy: *const fn (core: *Core, state: *anyopaque) void,
};

//
// A function that gives the text of the error reply for an error a channel handler returned, or null to use the error's name.
//
pub const ErrorDescriber = types.ErrorDescriber;

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
    .{
        .name = "get-platform",
        .handler = getPlatformHandler,
    },
    .{
        .name = "add-task",
        .handler = addTaskHandler,
    },
    .{
        .name = "cancel-tasks",
        .handler = cancelTasksHandler,
    },
    .{
        .name = "menu-action",
        .handler = menuActionHandler,
    },
    .{
        .name = "get-dropped-paths",
        .handler = getDroppedPathsHandler,
    },
} ++ if (build_options.test_hooks) [_]ChannelEntry{
    .{
        .name = "test-result",
        .handler = testResultHandler,
    },
    .{
        .name = "test-page-ready",
        .handler = testPageReadyHandler,
    },
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
    // The files of the app's bundled page, owned by the app.
    ui_files: []const ui_files.UiFile,
    // Gives the text of an error reply, or null to use the error's name. Owned by the app.
    describe_error: ?ErrorDescriber,
    // The app's way of making and destroying its state, or null.
    state_hooks: ?AppState,
    // The app's state, made by `state_hooks.create`, or null when the app has none.
    app_state: ?*anyopaque,
    // The app's function for a task that ended, or null.
    on_task_end: ?*const fn (core: *Core, end: types.TaskEnd) void,
    // The app's function for a message a task sent, or null.
    on_task_message: ?*const fn (core: *Core, sent: types.TaskSentMessage) void,
    // The app's function for the query of the page's address, or null.
    page_query: ?PageQuery,
    // The text the last call to `pageQuery` returned, owned by the core, or null before the first call.
    page_query_text: ?[:0]u8,
    // The shell's configuration. The strings in it are copies owned by the core.
    config: ZiggyConfig,
    // The owned copy of the app's URL prefix.
    app_url_prefix: [:0]u8,
    // The owned copy of the data directory.
    data_dir: [:0]u8,
    // The task runner.
    runner: task_runner.TaskRunner,
    // The IQueueBackend that code written against task-queue-zig talks to, backed by the runner.
    queue_backend: *queue_backend.ZiggyQueueBackend,
    // The files the user last dropped on the window, for getPathForFile.
    dropped: dropped_files.DroppedFiles,
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
        // The retry of utils-zig runs its operations against a timer, which needs the Io to start a task of its own. Everything else
        // still runs on the calling thread, and a cancel request still has no effect on it.
        core.threaded.allocator = allocator;
        core.threaded.concurrent_limit = .unlimited;
        const channels = try allocator.alloc(ChannelEntry, ziggy_channels.len + app.channels.len);
        errdefer allocator.free(channels);
        @memcpy(channels[0..ziggy_channels.len], &ziggy_channels);
        @memcpy(channels[ziggy_channels.len..], app.channels);
        core.channels = channels;
        core.tasks = app.tasks;
        core.task_channels = app.task_channels;
        core.next_request_task = .init(0);
        core.menu_json = app.menu_json;
        core.ui_files = app.ui_files;
        core.describe_error = app.describe_error;
        core.state_hooks = app.state;
        core.app_state = null;
        core.on_task_end = app.on_task_end;
        core.on_task_message = app.on_task_message;
        core.page_query = app.page_query;
        core.page_query_text = null;
        core.config = config;
        core.app_url_prefix = try allocator.dupeZ(u8, std.mem.span(config.app_url_prefix));
        errdefer allocator.free(core.app_url_prefix);
        core.data_dir = try allocator.dupeZ(u8, std.mem.span(config.data_dir));
        errdefer allocator.free(core.data_dir);
        // The shell's own strings are valid only during the call, so everything that keeps the configuration keeps it pointing at the copies.
        core.config.app_url_prefix = core.app_url_prefix.ptr;
        core.config.data_dir = core.data_dir.ptr;
        core.dropped = dropped_files.DroppedFiles.init(allocator);
        errdefer core.dropped.deinit();
        core.control = null;
        core.queue_backend = try queue_backend.ZiggyQueueBackend.create(allocator, core.threaded.io(), &core.runner);
        errdefer core.queue_backend.destroy();
        try core.runner.start(allocator, core.threaded.io(), .{
            .user_data = core,
            .emit = emitFromRunner,
        }, app.tasks, .{
            .worker_threads = config.worker_threads,
            .max_concurrent_child_tasks = config.max_concurrent_child_tasks,
            .describe_error = app.describe_error,
            .fallback_handler = queue_backend.fallbackHandler(core.queue_backend),
            .observer = .{
                .user_data = core,
                .on_task_end = observeTaskEnd,
                .on_task_message = observeTaskMessage,
            },
        }, core.config);
        errdefer core.runner.stop();
        task_queue.queue_backend.setQueueBackend(core.queue_backend.queueBackend());
        errdefer task_queue.queue_backend.setQueueBackend(null);
        if (app.state) |hooks| {
            core.app_state = try hooks.create(core);
            core.runner.app_state = core.app_state;
        }
        errdefer if (core.app_state) |state| {
            core.state_hooks.?.stop(core, state);
            core.state_hooks.?.destroy(core, state);
        };
        if (build_options.test_hooks) {
            if (config.test_mode) {
                const control = try allocator.create(test_control.TestControl);
                errdefer allocator.destroy(control);
                try control.start(allocator, core.threaded.io(), config, emitFromRunner, core, filesDroppedFromControl);
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
        if (self.app_state) |state| {
            self.state_hooks.?.stop(self, state);
        }
        if (self.control) |control| {
            control.stop();
            self.allocator.destroy(control);
        }
        self.runner.stop();
        if (self.app_state) |state| {
            self.state_hooks.?.destroy(self, state);
        }
        task_queue.queue_backend.setQueueBackend(null);
        self.queue_backend.destroy();
        self.threaded.deinit();
        self.dropped.deinit();
        if (self.page_query_text) |text| {
            self.allocator.free(text);
        }
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
    // Asks the app for the query of the page's address and returns the text after the question mark, empty when the app has none. The
    // text is owned by the core and stays valid until the next call or until the core is destroyed. The shell calls it once the core
    // exists, before it loads the page.
    //
    pub fn pageQuery(self: *Core) ![:0]const u8 {
        const page_query = self.page_query orelse {
            return "";
        };
        // The app allocates from an arena that goes when the call returns, so it need not free what it uses to make the text.
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const text = try page_query(self, arena_state.allocator(), self.config.test_mode);
        const owned = try self.allocator.dupeZ(u8, text);
        if (self.page_query_text) |old| {
            self.allocator.free(old);
        }
        self.page_query_text = owned;
        return owned;
    }

    //
    // Finds the bundled page's file for the path of a request, or null when the page has no such file. See ui-files.zig.
    //
    pub fn uiFile(self: *Core, request_path: []const u8) ?*const ui_files.UiFile {
        return ui_files.findFile(self.ui_files, request_path);
    }

    //
    // Records the files the user dropped on the window, replacing the last drop. The shell calls it when the drop happens, before the
    // page's own drop event, with the paths as the JSON text of an array of strings.
    //
    pub fn filesDropped(self: *Core, paths_json: []const u8) !void {
        try self.dropped.replace(self.io(), paths_json);
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
            const described: ?[]const u8 = if (self.describe_error) |describe| describe(err) else null;
            self.reportError(arena, request_id, described orelse @errorName(err));
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
        self.runner.addTask(task_id, entry.task_type, "request", data_json, .interactive, id_json) catch |err| {
            self.reportError(arena, id, @errorName(err));
        };
    }

    //
    // Sends the successful reply to a request.
    //
    fn sendReply(self: *Core, arena: std.mem.Allocator, id: std.json.Value, reply_data: []const u8) !void {
        const reply = try json_util.stringify(arena, .{
            .id = id,
            .ok = true,
            .data = json_util.Raw{
                .text = reply_data,
            },
        });
        self.deliver(reply);
    }

    //
    // Answers a request with an error reply, or, when there is nothing to reply to, sends a core-error event.
    //
    fn reportError(self: *Core, arena: std.mem.Allocator, id: ?std.json.Value, error_name: []const u8) void {
        if (id) |id_value| {
            const reply = json_util.stringify(arena, .{
                .id = id_value,
                .ok = false,
                .@"error" = error_name,
            }) catch {
                @panic("out of memory building an error message");
            };
            self.deliver(reply);
            return;
        }
        const event = json_util.stringify(arena, .{
            .channel = "core-error",
            .data = .{
                .@"error" = error_name,
            },
        }) catch {
            @panic("out of memory building an error message");
        };
        self.deliver(event);
    }
};

//
// The runner calls this when a task has ended: tells the queue backend, then the app.
//
fn observeTaskEnd(user_data: ?*anyopaque, end: types.TaskEnd) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.queue_backend.taskEnded(end);
    if (core.on_task_end) |on_task_end| {
        on_task_end(core, end);
    }
}

//
// The runner calls this when a task has sent a message: tells the queue backend, then the app.
//
fn observeTaskMessage(user_data: ?*anyopaque, sent: types.TaskSentMessage) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.queue_backend.messageSent(sent);
    if (core.on_task_message) |on_task_message| {
        on_task_message(core, sent);
    }
}

//
// Delivers a message the runner or the test control connection produced to the shell.
//
fn emitFromRunner(user_data: ?*anyopaque, message: []const u8) void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    core.deliver(message);
}

//
// Answers get-platform: whether the platform is a desktop or a mobile one, and the operating system and architecture.
//
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

//
// Answers add-task: queues the task the page asked for.
//
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
    const priority_field: std.json.Value = if (data.object.get("priority")) |field| field else .null;
    const priority = switch (priority_field) {
        .null => try priorityFromText(null),
        .string => |text| try priorityFromText(text),
        else => return error.UnknownPriority,
    };
    const task_data: std.json.Value = if (data.object.get("data")) |value| value else .null;
    const data_json = try json_util.stringify(arena, task_data);
    try core.runner.addTask(task_id, task_type, source, data_json, priority, null);
    return try arena.dupe(u8, "{}");
}

//
// Turns the priority of an add-task request into the runner's TaskPriority. The page sends TaskPriority, "interactive" or
// "background", and leaves it out when the task has no preference, which runs as background.
//
pub fn priorityFromText(text: ?[]const u8) !task_runner.TaskPriority {
    const priority = text orelse {
        return .background;
    };
    if (std.mem.eql(u8, priority, "interactive")) {
        return .interactive;
    }
    if (std.mem.eql(u8, priority, "background")) {
        return .background;
    }
    return error.UnknownPriority;
}

//
// Cancels the tasks queued under a source. The page sends the source as a bare string.
//
fn cancelTasksHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    if (data != .string) {
        return error.MissingSource;
    }
    const source = data.string;
    core.runner.cancelSource(source);
    return try arena.dupe(u8, "{}");
}

//
// Answers test-result: hands the result the page computed for a test control request to the connection waiting for it.
//
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

//
// Answers test-page-ready: tells the test control connection the page has loaded.
//
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
    const event = try json_util.stringify(arena, .{
        .channel = "menu-action",
        .data = .{
            .action = action,
        },
    });
    core.deliver(event);
    return try arena.dupe(u8, "{}");
}

//
// What the test control connection calls for its drop command: records the files as the shell does when the user drops them.
//
fn filesDroppedFromControl(user_data: ?*anyopaque, paths_json: []const u8) anyerror!void {
    const core: *Core = @ptrCast(@alignCast(user_data.?));
    try core.filesDropped(paths_json);
}

//
// Answers the page's request for the paths of the files in the last drop, as an array of strings (empty when nothing was dropped).
//
fn getDroppedPathsHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = data;
    return try core.dropped.pathsJson(core.io(), arena);
}
