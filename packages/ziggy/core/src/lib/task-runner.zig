//
// The task runner: runs task handlers on a pool of threads, with priorities, cancellation by source and child tasks.
//
// Children run on the same pool as their parent. A parent that waits for a child does not hold its worker idle:
// it runs queued children of its own on its thread while it waits, so the pool cannot deadlock when every
// worker is held by a parent that is waiting for children.
//

const std = @import("std");
const types = @import("types.zig");
const json_util = @import("json-util.zig");

const Completion = types.Completion;
const TaskStatus = types.TaskStatus;
const ZiggyConfig = types.ZiggyConfig;

//
// A handler for one task type. It returns the JSON text of its result (allocated with the context's allocator), or
// null for none. It returns error.Cancelled when it stops because its task was cancelled.
//
pub const TaskHandler = *const fn (context: *TaskContext, data: std.json.Value) anyerror!?[]const u8;

//
// Whether a task type keeps the app running when the app is not in the foreground. A task of a keep-alive type that is queued or
// running makes the core ask the shell to keep the app running, until the last such task ends.
//
pub const TaskKind = enum {
    // An ordinary task. The platform may stop it when the app is in the background.
    normal,
    // A task the app must be kept running for, on every platform, by the means that platform has.
    keep_alive,
};

//
// A task type and its handler.
//
pub const TaskHandlerEntry = struct {
    // The task type string the page queues the task under.
    name: []const u8,
    // The function that runs the task.
    handler: TaskHandler,
    // Whether the app is kept running for tasks of this type. A child task takes its parent's kind.
    kind: TaskKind = .normal,
};

//
// Where the runner sends the events it produces (task-message and task-completed), as JSON text.
//
pub const EventSink = struct {
    // The sink's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Delivers one event. It is called from any thread and the text is valid only during the call.
    emit: *const fn (user_data: ?*anyopaque, message: []const u8) void,
};

//
// The settings of a runner.
//
pub const TaskRunnerOptions = struct {
    // The number of worker threads.
    worker_threads: u32,
    // The limit on child tasks in flight for any one parent task.
    max_concurrent_child_tasks: u32,
};

//
// Lets a test answer a native dialog without one being shown. The control connection of a test hooks build provides it.
//
pub const PickOverride = struct {
    // The provider's own pointer, passed back on every call.
    user_data: ?*anyopaque,
    // Takes the answer a test has given for the next dialog, as the JSON text of an array of paths allocated with the
    // allocator, or returns null when the test gave none. An answer answers one dialog.
    take: *const fn (user_data: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8,
};

//
// What a task is waiting for while it helps run its children.
//
const WaitKind = enum {
    // One named child to finish.
    task,
    // Every child to finish.
    all,
    // A free place under the child task limit.
    slot,
};

const TaskState = enum {
    queued,
    running,
    done,
};

//
// One task, queued or running or finished. Children stay in their parent's list until the parent is released, so a
// parent can await one after it has finished.
//
const Task = struct {
    // The id the page gave the task, or the parent's id with a child suffix for a child.
    id: []u8,
    // The task type string.
    task_type: []u8,
    // The source the task was queued under. A child has its parent's source.
    source: []u8,
    // The task's input data as JSON text.
    data_json: []u8,
    // Higher runs first.
    priority: i32,
    // Queue order, which breaks ties between equal priorities.
    sequence: u64,
    // Set when the task's source is cancelled. Only ever set on a task that already exists.
    cancelled: std.atomic.Value(bool),
    // The task that queued this one.
    parent: ?*Task,
    // Whether the app is kept running for this task: a top level task whose type is keep-alive. A child is covered by its parent, which
    // lives at least as long, so it takes its parent's kind without being counted again.
    keep_alive: bool,
    // Where the task is in its life.
    state: TaskState,
    // Children that have been queued and have not finished.
    inflight_children: u32,
    // Every child, finished or not.
    children: std.ArrayList(*Task),
    // The number of children queued so far, which names the next one.
    next_child: u32,
    // How the task ended, once it has.
    completion: ?Completion,
    // For a task that answers a request from the page: the JSON text of the request's id. When the task ends the core sends the
    // reply to that request, instead of the task-completed event. Owned.
    reply_id_json: ?[]u8,
};

//
// What a handler works with while it runs.
//
pub const TaskContext = struct {
    // The runner running the task.
    runner: *TaskRunner,
    // The task being run.
    task: *Task,
    // Freed when the task ends. Everything a handler allocates for its result goes here.
    arena: std.mem.Allocator,

    //
    // The id of the task.
    //
    pub fn taskId(self: *TaskContext) []const u8 {
        return self.task.id;
    }

    //
    // The source the task was queued under.
    //
    pub fn source(self: *TaskContext) []const u8 {
        return self.task.source;
    }

    //
    // The limit on child tasks in flight for this task.
    //
    pub fn maxConcurrentChildTasks(self: *TaskContext) u32 {
        return self.runner.options.max_concurrent_child_tasks;
    }

    //
    // The configuration the shell gave the core, for host callbacks.
    //
    pub fn config(self: *TaskContext) *const ZiggyConfig {
        return &self.runner.config;
    }

    //
    // The Io for sleeping and for file access.
    //
    pub fn io(self: *TaskContext) std.Io {
        return self.runner.io;
    }

    //
    // Whether the task's source has been cancelled.
    //
    pub fn isCancelled(self: *TaskContext) bool {
        return self.task.cancelled.load(.acquire);
    }

    //
    // Returns error.Cancelled when the task's source has been cancelled.
    //
    pub fn checkCancelled(self: *TaskContext) !void {
        if (self.isCancelled()) {
            return error.Cancelled;
        }
    }

    //
    // Sends any value std.json can serialise to the page as the message of a task-message event.
    //
    pub fn sendMessage(self: *TaskContext, message: anytype) !void {
        const json = try json_util.stringify(self.arena, message);
        try self.sendRawMessage(json);
    }

    //
    // Sends JSON text to the page as the message of a task-message event.
    //
    pub fn sendRawMessage(self: *TaskContext, json: []const u8) !void {
        try self.runner.emitTaskMessage(self.task, json);
    }

    //
    // Queues a child task and returns its id. Waits, running other children of this task, while the limit on child
    // tasks in flight is reached. Returns error.Cancelled when this task has been cancelled.
    //
    pub fn queueChild(self: *TaskContext, task_type: []const u8, data: anytype) ![]const u8 {
        const data_json = try json_util.stringify(self.arena, data);
        const child_id = try self.runner.queueChild(self.task, task_type, data_json);
        return try self.arena.dupe(u8, child_id);
    }

    //
    // Waits for one child to finish, running queued children of this task while it waits, and returns how it ended.
    // A failed child is returned as a failure, never hidden.
    //
    pub fn awaitTask(self: *TaskContext, child_id: []const u8) !Completion {
        return try self.runner.awaitTask(self.task, child_id, self.arena);
    }

    //
    // Waits for every child to finish, running queued children of this task while it waits.
    //
    pub fn awaitAllTasks(self: *TaskContext) void {
        self.runner.awaitAllTasks(self.task);
    }

    //
    // Shows a native file or folder dialog through the shell's native host callback, and returns what the user chose as the
    // JSON text of an array of path strings, empty when they cancelled. The dialog is shown on the shell's UI thread while this
    // waits, so it must be called from a task. A test hooks build lets a test answer instead, and no dialog is shown.
    //
    pub fn pickPaths(self: *TaskContext, kind: types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) ![]const u8 {
        if (self.runner.pick_override) |override| {
            if (override.take(override.user_data, self.arena)) |answer| {
                return answer;
            }
        }
        const pick = self.runner.config.pick_paths orelse {
            return error.HostCallbackMissing;
        };
        const title_text: ?[:0]const u8 = if (title) |text| try self.arena.dupeZ(u8, text) else null;
        const name_text: ?[:0]const u8 = if (initial_name) |text| try self.arena.dupeZ(u8, text) else null;
        const buffer = try self.arena.alloc(u8, 64 * 1024);
        const length = pick(self.runner.config.user_data, @intFromEnum(kind), if (title_text) |text| text.ptr else null, if (name_text) |text| text.ptr else null, buffer.ptr, buffer.len);
        if (length < 0) {
            return error.HostCallbackFailed;
        }
        return buffer[0..@intCast(length)];
    }
};

//
// The pool of threads and the queue of tasks.
//
pub const TaskRunner = struct {
    // Allocates tasks and events.
    allocator: std.mem.Allocator,
    // For the mutex, the condition and sleeping.
    io: std.Io,
    // Where events go.
    sink: EventSink,
    // The task types that can run.
    handlers: []const TaskHandlerEntry,
    // The runner's settings.
    options: TaskRunnerOptions,
    // The shell's configuration, for host callbacks.
    config: ZiggyConfig,
    // Guards everything below.
    mutex: std.Io.Mutex,
    // Signalled whenever a task is queued, finishes or is cancelled.
    changed: std.Io.Condition,
    // Tasks waiting to run.
    queue: std.ArrayList(*Task),
    // Top level tasks that have not finished.
    live: std.ArrayList(*Task),
    // The worker threads.
    workers: std.ArrayList(std.Thread),
    // The number of tasks queued so far, which orders the queue.
    next_sequence: u64,
    // Set once shutdown has begun.
    shutting_down: bool,
    // Answers dialogs for a test, when the test hooks provide it.
    pick_override: ?PickOverride,
    // Set once shutdown has begun, so that nothing more is sent to the shell.
    silent: std.atomic.Value(bool),
    // The number of top level keep-alive tasks that are queued or running. Guarded by the mutex.
    keep_alive_count: u32,

    //
    // Creates a runner and starts its worker threads. It must stay where it is: the threads hold its address.
    //
    pub fn start(self: *TaskRunner, allocator: std.mem.Allocator, io: std.Io, sink: EventSink, handlers: []const TaskHandlerEntry, options: TaskRunnerOptions, config: ZiggyConfig) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .sink = sink,
            .handlers = handlers,
            .options = options,
            .config = config,
            .mutex = .init,
            .changed = .init,
            .queue = .empty,
            .live = .empty,
            .workers = .empty,
            .next_sequence = 0,
            .shutting_down = false,
            .pick_override = null,
            .silent = .init(false),
            .keep_alive_count = 0,
        };
        errdefer self.stop();
        var worker_index: u32 = 0;
        while (worker_index < options.worker_threads) : (worker_index += 1) {
            const thread = try std.Thread.spawn(.{}, workerMain, .{self});
            try self.workers.append(allocator, thread);
        }
    }

    //
    // Cancels every task, waits for the workers to stop and releases everything. No task runs after it returns,
    // and nothing is sent to the shell once it has begun.
    //
    pub fn stop(self: *TaskRunner) void {
        self.silent.store(true, .release);
        self.lock();
        self.shutting_down = true;
        for (self.live.items) |task| {
            cancelTree(task);
        }
        for (self.queue.items) |task| {
            task.cancelled.store(true, .release);
        }
        self.changed.broadcast(self.io);
        self.unlock();
        for (self.workers.items) |thread| {
            thread.join();
        }
        self.workers.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.live.deinit(self.allocator);
    }

    //
    // Queues a top level task and returns at once. The ids of live tasks must be unique. When reply_id_json is given, the task
    // answers the page request with that id: its end is reported as that request's reply, and no task-completed event is sent.
    //
    pub fn addTask(self: *TaskRunner, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: i32, reply_id_json: ?[]const u8) !void {
        const task = try self.createTask(task_id, task_type, source, data_json, priority, null);
        if (reply_id_json) |reply_id| {
            task.reply_id_json = try self.allocator.dupe(u8, reply_id);
        }
        errdefer self.destroyTask(task);
        self.lock();
        defer self.unlock();
        if (self.shutting_down) {
            return error.ShuttingDown;
        }
        for (self.live.items) |live_task| {
            if (std.mem.eql(u8, live_task.id, task_id)) {
                return error.DuplicateTaskId;
            }
        }
        task.sequence = self.next_sequence;
        self.next_sequence += 1;
        try self.live.append(self.allocator, task);
        errdefer _ = self.live.pop();
        try self.queue.append(self.allocator, task);
        if (task.keep_alive) {
            self.keep_alive_count += 1;
            if (self.keep_alive_count == 1) {
                self.callKeepAlive(true);
            }
        }
        self.changed.broadcast(self.io);
    }

    //
    // The kind of a task type, normal when the type is not known (the task then fails as an unknown type).
    //
    fn kindOf(self: *TaskRunner, task_type: []const u8) TaskKind {
        for (self.handlers) |entry| {
            if (std.mem.eql(u8, entry.name, task_type)) {
                return entry.kind;
            }
        }
        return .normal;
    }

    //
    // Tells the shell to keep the app running, or that it need not. Called while the lock is held, so the shell hears the changes in
    // the order they happen. Nothing is sent once shutdown has begun.
    //
    fn callKeepAlive(self: *TaskRunner, keep_running: bool) void {
        if (self.silent.load(.acquire)) {
            return;
        }
        const keep_alive = self.config.keep_alive orelse {
            return;
        };
        keep_alive(self.config.user_data, keep_running);
    }

    //
    // Cancels every queued or running task queued under the source. A queued task never starts. A running task is
    // told to stop and ends as cancelled. Tasks queued under the source afterwards are not affected.
    //
    pub fn cancelSource(self: *TaskRunner, source: []const u8) void {
        var removed: std.ArrayList(*Task) = .empty;
        defer removed.deinit(self.allocator);
        self.lock();
        for (self.live.items) |task| {
            if (std.mem.eql(u8, task.source, source)) {
                cancelTree(task);
            }
        }
        var index: usize = 0;
        while (index < self.queue.items.len) {
            const task = self.queue.items[index];
            if (task.cancelled.load(.acquire) and task.state == .queued and task.children.items.len == 0) {
                _ = self.queue.orderedRemove(index);
                removed.append(self.allocator, task) catch @panic("out of memory cancelling a task");
                continue;
            }
            index += 1;
        }
        self.changed.broadcast(self.io);
        self.unlock();
        for (removed.items) |task| {
            self.finish(task, .{
                .status = .cancelled,
                .result_json = null,
                .error_message = null,
            });
        }
    }

    fn lock(self: *TaskRunner) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *TaskRunner) void {
        self.mutex.unlock(self.io);
    }

    //
    // Marks a task and everything under it as cancelled. The caller holds the lock.
    //
    fn cancelTree(task: *Task) void {
        task.cancelled.store(true, .release);
        for (task.children.items) |child| {
            cancelTree(child);
        }
    }

    fn createTask(self: *TaskRunner, task_id: []const u8, task_type: []const u8, source: []const u8, data_json: []const u8, priority: i32, parent: ?*Task) !*Task {
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        const id = try self.allocator.dupe(u8, task_id);
        errdefer self.allocator.free(id);
        const type_copy = try self.allocator.dupe(u8, task_type);
        errdefer self.allocator.free(type_copy);
        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);
        const data_copy = try self.allocator.dupe(u8, data_json);
        task.* = .{
            .id = id,
            .task_type = type_copy,
            .source = source_copy,
            .data_json = data_copy,
            .priority = priority,
            .sequence = 0,
            .cancelled = .init(false),
            .parent = parent,
            .keep_alive = parent == null and self.kindOf(task_type) == .keep_alive,
            .state = .queued,
            .inflight_children = 0,
            .children = .empty,
            .next_child = 0,
            .completion = null,
            .reply_id_json = null,
        };
        return task;
    }

    //
    // Releases a task and its children.
    //
    fn destroyTask(self: *TaskRunner, task: *Task) void {
        for (task.children.items) |child| {
            self.destroyTask(child);
        }
        task.children.deinit(self.allocator);
        if (task.completion) |completion| {
            if (completion.result_json) |text| {
                self.allocator.free(text);
            }
            if (completion.error_message) |text| {
                self.allocator.free(text);
            }
        }
        self.allocator.free(task.id);
        self.allocator.free(task.task_type);
        self.allocator.free(task.source);
        self.allocator.free(task.data_json);
        if (task.reply_id_json) |reply_id| {
            self.allocator.free(reply_id);
        }
        self.allocator.destroy(task);
    }

    //
    // Removes the queued task that should run next from the queue and returns it. A task is picked from all of
    // the queue, or, when a parent is given, only from the parent's own children. The caller holds the lock.
    //
    fn takeNext(self: *TaskRunner, parent: ?*Task) ?*Task {
        var best_index: ?usize = null;
        for (self.queue.items, 0..) |task, index| {
            if (parent != null and task.parent != parent) {
                continue;
            }
            if (best_index) |best| {
                const best_task = self.queue.items[best];
                if (task.priority > best_task.priority or (task.priority == best_task.priority and task.sequence < best_task.sequence)) {
                    best_index = index;
                }
            }
            else {
                best_index = index;
            }
        }
        const index = best_index orelse {
            return null;
        };
        const task = self.queue.orderedRemove(index);
        task.state = .running;
        return task;
    }

    fn workerMain(self: *TaskRunner) void {
        while (true) {
            self.lock();
            var next: ?*Task = null;
            while (true) {
                next = self.takeNext(null);
                if (next != null or self.shutting_down) {
                    break;
                }
                self.changed.waitUncancelable(self.io, &self.mutex);
            }
            self.unlock();
            const task = next orelse {
                return;
            };
            self.runTask(task);
        }
    }

    //
    // Runs one task on the calling thread to its end and reports its completion.
    //
    fn runTask(self: *TaskRunner, task: *Task) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var context = TaskContext{
            .runner = self,
            .task = task,
            .arena = arena,
        };
        var completion: Completion = .{
            .status = .succeeded,
            .result_json = null,
            .error_message = null,
        };
        if (task.cancelled.load(.acquire)) {
            completion.status = .cancelled;
        }
        else {
            completion = self.callHandler(&context, arena);
        }
        // A parent never ends while a child is still running.
        self.awaitAllTasks(task);
        self.finish(task, completion);
    }

    fn callHandler(self: *TaskRunner, context: *TaskContext, arena: std.mem.Allocator) Completion {
        const task = context.task;
        var handler: ?TaskHandler = null;
        for (self.handlers) |entry| {
            if (std.mem.eql(u8, entry.name, task.task_type)) {
                handler = entry.handler;
                break;
            }
        }
        const found = handler orelse {
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = "UnknownTaskType",
            };
        };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, task.data_json, .{}) catch {
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = "InvalidTaskData",
            };
        };
        const result = found(context, parsed) catch |err| {
            if (err == error.Cancelled) {
                return .{
                    .status = .cancelled,
                    .result_json = null,
                    .error_message = null,
                };
            }
            return .{
                .status = .failed,
                .result_json = null,
                .error_message = @errorName(err),
            };
        };
        if (task.cancelled.load(.acquire)) {
            return .{
                .status = .cancelled,
                .result_json = null,
                .error_message = null,
            };
        }
        return .{
            .status = .succeeded,
            .result_json = result,
            .error_message = null,
        };
    }

    //
    // Records how a task ended, tells the page, then tells the parent, and releases a top level task. The page is told
    // first because the moment the parent knows a child is done it may release that child.
    //
    fn finish(self: *TaskRunner, task: *Task, completion: Completion) void {
        const is_top_level = task.parent == null;
        const parent = task.parent;
        if (task.reply_id_json) |reply_id| {
            self.emitReply(reply_id, completion);
        }
        else {
            self.emitTaskCompleted(task, completion);
        }
        const result_copy: ?[]u8 = if (completion.result_json) |text| self.allocator.dupe(u8, text) catch @panic("out of memory recording a task completion") else null;
        const error_copy: ?[]u8 = if (completion.error_message) |text| self.allocator.dupe(u8, text) catch @panic("out of memory recording a task completion") else null;
        self.lock();
        task.state = .done;
        task.completion = .{
            .status = completion.status,
            .result_json = result_copy,
            .error_message = error_copy,
        };
        if (is_top_level) {
            for (self.live.items, 0..) |live_task, index| {
                if (live_task == task) {
                    _ = self.live.orderedRemove(index);
                    break;
                }
            }
            if (task.keep_alive) {
                self.keep_alive_count -= 1;
                if (self.keep_alive_count == 0) {
                    self.callKeepAlive(false);
                }
            }
        }
        if (parent) |parent_task| {
            parent_task.inflight_children -= 1;
        }
        self.changed.broadcast(self.io);
        self.unlock();
        if (is_top_level) {
            self.destroyTask(task);
        }
    }

    fn queueChild(self: *TaskRunner, parent: *Task, task_type: []const u8, data_json: []const u8) ![]const u8 {
        self.lock();
        defer self.unlock();
        if (parent.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        self.waitHelping(parent, .slot, null);
        if (parent.cancelled.load(.acquire)) {
            return error.Cancelled;
        }
        var id_buffer: [512]u8 = undefined;
        const child_id = try std.fmt.bufPrint(&id_buffer, "{s}.c{d}", .{ parent.id, parent.next_child });
        const child = try self.createTask(child_id, task_type, parent.source, data_json, parent.priority, parent);
        errdefer self.destroyTask(child);
        child.sequence = self.next_sequence;
        self.next_sequence += 1;
        try parent.children.append(self.allocator, child);
        errdefer _ = parent.children.pop();
        try self.queue.append(self.allocator, child);
        parent.next_child += 1;
        parent.inflight_children += 1;
        self.changed.broadcast(self.io);
        return child.id;
    }

    fn awaitTask(self: *TaskRunner, parent: *Task, child_id: []const u8, arena: std.mem.Allocator) !Completion {
        self.lock();
        defer self.unlock();
        var target: ?*Task = null;
        for (parent.children.items) |child| {
            if (std.mem.eql(u8, child.id, child_id)) {
                target = child;
                break;
            }
        }
        const child = target orelse {
            return error.UnknownChildTask;
        };
        self.waitHelping(parent, .task, child);
        const completion = child.completion.?;
        return .{
            .status = completion.status,
            .result_json = if (completion.result_json) |text| try arena.dupe(u8, text) else null,
            .error_message = if (completion.error_message) |text| try arena.dupe(u8, text) else null,
        };
    }

    fn awaitAllTasks(self: *TaskRunner, parent: *Task) void {
        self.lock();
        defer self.unlock();
        self.waitHelping(parent, .all, null);
    }

    //
    // Waits until the condition holds, running queued children of the parent on this thread whenever there is one.
    // Called, and returns, with the lock held.
    //
    fn waitHelping(self: *TaskRunner, parent: *Task, kind: WaitKind, target: ?*Task) void {
        while (!self.conditionMet(parent, kind, target)) {
            if (self.takeNext(parent)) |child| {
                self.unlock();
                self.runTask(child);
                self.lock();
                continue;
            }
            self.changed.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn conditionMet(self: *TaskRunner, parent: *Task, kind: WaitKind, target: ?*Task) bool {
        return switch (kind) {
            .task => target.?.state == .done,
            .all => parent.inflight_children == 0,
            .slot => parent.inflight_children < self.options.max_concurrent_child_tasks or parent.cancelled.load(.acquire),
        };
    }

    fn emitTaskMessage(self: *TaskRunner, task: *Task, message_json: []const u8) !void {
        if (self.silent.load(.acquire)) {
            return;
        }
        const id = try json_util.stringify(self.allocator, task.id);
        defer self.allocator.free(id);
        const source = try json_util.stringify(self.allocator, task.source);
        defer self.allocator.free(source);
        const event = try std.fmt.allocPrint(self.allocator, "{{\"channel\":\"task-message\",\"data\":{{\"taskId\":{s},\"source\":{s},\"message\":{s}}}}}", .{ id, source, message_json });
        defer self.allocator.free(event);
        self.sink.emit(self.sink.user_data, event);
    }
    //
    // Sends the reply to the page request a task was answering: the task's result on success, or an error reply saying why not.
    //
    fn emitReply(self: *TaskRunner, reply_id_json: []const u8, completion: Completion) void {
        if (self.silent.load(.acquire)) {
            return;
        }
        const event = switch (completion.status) {
            .succeeded => std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"ok\":true,\"data\":{s}}}", .{ reply_id_json, completion.result_json orelse "null" }),
            .cancelled => std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"ok\":false,\"error\":\"Cancelled\"}}", .{reply_id_json}),
            .failed => std.fmt.allocPrint(self.allocator, "{{\"id\":{s},\"ok\":false,\"error\":\"{s}\"}}", .{ reply_id_json, completion.error_message orelse "Failed" }),
        } catch @panic("out of memory building a reply");
        defer self.allocator.free(event);
        self.sink.emit(self.sink.user_data, event);
    }


    fn emitTaskCompleted(self: *TaskRunner, task: *Task, completion: Completion) void {
        if (self.silent.load(.acquire)) {
            return;
        }
        const id = json_util.stringify(self.allocator, task.id) catch @panic("out of memory building a task event");
        defer self.allocator.free(id);
        const source = json_util.stringify(self.allocator, task.source) catch @panic("out of memory building a task event");
        defer self.allocator.free(source);
        var detail: []u8 = &.{};
        defer if (detail.len > 0) self.allocator.free(detail);
        if (completion.result_json) |result| {
            detail = std.fmt.allocPrint(self.allocator, ",\"result\":{s}", .{result}) catch @panic("out of memory building a task event");
        }
        else if (completion.error_message) |error_message| {
            const error_json = json_util.stringify(self.allocator, error_message) catch @panic("out of memory building a task event");
            defer self.allocator.free(error_json);
            detail = std.fmt.allocPrint(self.allocator, ",\"error\":{s}", .{error_json}) catch @panic("out of memory building a task event");
        }
        const event = std.fmt.allocPrint(self.allocator, "{{\"channel\":\"task-completed\",\"data\":{{\"taskId\":{s},\"source\":{s},\"status\":\"{s}\"{s}}}}}", .{ id, source, @tagName(completion.status), detail }) catch @panic("out of memory building a task event");
        defer self.allocator.free(event);
        self.sink.emit(self.sink.user_data, event);
    }
};
