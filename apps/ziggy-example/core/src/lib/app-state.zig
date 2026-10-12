//
// What the example keeps while it runs, and the parts of Ziggy that reach it: the state the core holds for the app, the observers the
// core calls when a task ends or sends a message, the describer that turns an error into the text of its reply, and channels that
// queue, cancel and announce work from the app's own code rather than from the page.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// The example's state: counts of what the core has told it about tasks.
//
pub const ExampleState = struct {
    // Guards the counts, which the observers update from the threads that run tasks.
    mutex: std.Io.Mutex,
    // The Io the mutex is used with.
    io: std.Io,
    // How many tasks have ended.
    tasks_ended: u64,
    // How many messages tasks have sent.
    messages_sent: u64,
    // Whether the core has stopped the state, which it does before the task runner stops.
    stopped: bool,

    //
    // Takes the lock that guards the counts.
    //
    fn lock(self: *ExampleState) void {
        self.mutex.lockUncancelable(self.io);
    }

    //
    // Releases the lock that guards the counts.
    //
    fn unlock(self: *ExampleState) void {
        self.mutex.unlock(self.io);
    }
};

//
// The counts as the task-stats channel and the describe-self task reply with them.
//
const ITaskStats = struct {
    // How many tasks have ended.
    tasksEnded: u64,
    // How many messages tasks have sent.
    messagesSent: u64,
};

//
// The state hooks the example gives the core.
//
pub const state_hooks = ziggy.core.AppState{
    .create = create,
    .stop = stop,
    .destroy = destroy,
};

//
// Makes the example's state, with no tasks counted.
//
fn create(core: *Core) anyerror!*anyopaque {
    const state = try core.allocator.create(ExampleState);
    state.* = .{
        .mutex = .init,
        .io = core.io(),
        .tasks_ended = 0,
        .messages_sent = 0,
        .stopped = false,
    };
    return state;
}

//
// Records that the core has stopped the state. Nothing of the example's runs by itself, so there is nothing else to stop.
//
fn stop(core: *Core, opaque_state: *anyopaque) void {
    _ = core;
    const state: *ExampleState = @ptrCast(@alignCast(opaque_state));
    state.lock();
    defer state.unlock();
    state.stopped = true;
}

//
// Releases the example's state.
//
fn destroy(core: *Core, opaque_state: *anyopaque) void {
    const state: *ExampleState = @ptrCast(@alignCast(opaque_state));
    core.allocator.destroy(state);
}

//
// The example's state, from the core that holds it.
//
fn fromCore(core: *Core) *ExampleState {
    return @ptrCast(@alignCast(core.app_state.?));
}

//
// The counts, read under the lock.
//
fn readStats(state: *ExampleState) ITaskStats {
    state.lock();
    defer state.unlock();
    return .{
        .tasksEnded = state.tasks_ended,
        .messagesSent = state.messages_sent,
    };
}

//
// The core's observer of a task that has ended: counts it.
//
pub fn onTaskEnd(core: *Core, end: ziggy.types.TaskEnd) void {
    _ = end;
    const state = fromCore(core);
    state.lock();
    defer state.unlock();
    state.tasks_ended += 1;
}

//
// The core's observer of a message a task sent: counts it.
//
pub fn onTaskMessage(core: *Core, sent: ziggy.types.TaskSentMessage) void {
    _ = sent;
    const state = fromCore(core);
    state.lock();
    defer state.unlock();
    state.messages_sent += 1;
}

//
// Replies with how many tasks have ended and how many messages tasks have sent since the app started.
//
pub fn taskStatsHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = data;
    return try json_util.stringify(arena, readStats(fromCore(core)));
}

//
// Always fails with an error the example's describer has a sentence for, so the page can check the sentence is what reaches it.
//
pub fn refuseHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    _ = arena;
    _ = data;
    return error.Refused;
}

//
// The example's error describer: a sentence for the error the refuse channel returns, and nothing for any other, which is then replied
// to by name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Refused) {
        return "The example refused, as it was asked to.";
    }
    return null;
}

//
// Queues a hello-short task from the app's own code, under the source given in "source", and tells the page with an app-event that it
// did. The reply is the id of the task.
//
pub fn queueFromAppHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const source = json_util.getString(data, "source") orelse {
        return error.MissingSource;
    };
    const task_id = try std.fmt.allocPrint(arena, "from-app-{s}", .{source});
    try core.runner.addTask(task_id, "hello-short", source, "null", .background, null);
    core.deliver(try json_util.stringify(arena, .{
        .channel = "app-event",
        .data = .{
            .queued = task_id,
        },
    }));
    return try json_util.stringify(arena, task_id);
}

//
// Cancels, from the app's own code, the tasks queued under the source given in "source".
//
pub fn cancelFromAppHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const source = json_util.getString(data, "source") orelse {
        return error.MissingSource;
    };
    core.runner.cancelSource(source);
    return try arena.dupe(u8, "{}");
}

//
// Replies with what a task knows about itself from its context (its id, type and source, and the child task limit) and the counts the
// app's state holds, which it reaches through its context.
//
pub fn describeSelfHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const state: *ExampleState = @ptrCast(@alignCast(context.appState().?));
    return try json_util.stringify(context.arena, .{
        .taskId = context.taskId(),
        .taskType = context.taskType(),
        .source = context.source(),
        .maxConcurrentChildTasks = context.maxConcurrentChildTasks(),
        .stats = readStats(state),
    });
}

//
// Runs "children" hello-child tasks one after another, each freed as soon as it ends, and stops starting them once the task is cancelled,
// saying in an output message how many it ran. Replies with how many ran and how each ended.
//
pub fn runInTurnHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const children = json_util.getInteger(data, "children") orelse 0;
    var statuses: std.ArrayList([]const u8) = .empty;
    var index: i64 = 0;
    while (index < children and !context.isCancelled()) : (index += 1) {
        // A cancel that lands while the child is being queued ends the call with error.Cancelled instead of a cancelled completion.
        const completion = context.runChild(context.arena, "hello-child", .{
            .index = index,
        }, null) catch |err| switch (err) {
            error.Cancelled => break,
            else => return err,
        };
        try statuses.append(context.arena, @tagName(completion.status));
    }
    if (context.isCancelled()) {
        try context.sendMessage(.{
            .type = "output",
            .text = try std.fmt.allocPrint(context.arena, "run-in-turn stopped after {d} children", .{statuses.items.len}),
        });
        return error.Cancelled;
    }
    return try json_util.stringify(context.arena, .{
        .ran = statuses.items.len,
        .statuses = statuses.items,
    });
}
