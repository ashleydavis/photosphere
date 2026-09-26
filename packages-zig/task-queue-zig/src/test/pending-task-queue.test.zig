const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const types = task_queue_zig.types;
const ITask = types.ITask;
const TaskPriority = types.TaskPriority;
const DEFAULT_TASK_PRIORITY = types.DEFAULT_TASK_PRIORITY;
const insertTaskByPriority = task_queue_zig.pending_task_queue.insertTaskByPriority;
const resolveTaskPriority = task_queue_zig.pending_task_queue.resolveTaskPriority;

//
// Makes a pending task with the given id and priority. Nothing else about the task matters to the
// ordering, which is the point: these two functions decide order and nothing else.
//
fn pendingTask(id: []const u8, priority: TaskPriority) ITask {
    return .{
        .id = id,
        .type = "test-type",
        .status = .Pending,
        .data = .{ .object = .empty },
        .source = "test-source",
        .priority = priority,
        .createdAt = 1767225600000,
    };
}

//
// Checks the ids of the tasks in a pending queue, in the order they will be dispatched.
//
fn expectIds(expected: []const []const u8, pendingTasks: std.ArrayList(ITask)) !void {
    try std.testing.expectEqual(expected.len, pendingTasks.items.len);
    for (expected, pendingTasks.items) |expected_id, task| {
        try std.testing.expectEqualStrings(expected_id, task.id);
    }
}

test "a task that asked for nothing and has no parent runs at the default" {
    try std.testing.expectEqual(DEFAULT_TASK_PRIORITY, resolveTaskPriority(null, null));
}

test "the default is background, so nothing gets ahead of the user by accident" {
    try std.testing.expectEqual(TaskPriority.Background, DEFAULT_TASK_PRIORITY);
    try std.testing.expectEqualStrings("background", DEFAULT_TASK_PRIORITY.toString());
    try std.testing.expectEqualStrings("interactive", TaskPriority.Interactive.toString());
}

test "a child that asked for nothing inherits its parent's priority" {
    try std.testing.expectEqual(TaskPriority.Interactive, resolveTaskPriority(null, .Interactive));
    try std.testing.expectEqual(TaskPriority.Background, resolveTaskPriority(null, .Background));
}

test "a priority the caller asked for beats the parent's" {
    try std.testing.expectEqual(TaskPriority.Background, resolveTaskPriority(.Background, .Interactive));
    try std.testing.expectEqual(TaskPriority.Interactive, resolveTaskPriority(.Interactive, .Background));
}

test "an interactive task is dispatched before background tasks already queued" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-1", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-2", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));

    try expectIds(&.{ "interactive-1", "background-1", "background-2" }, pendingTasks);
}

test "a later interactive task goes in front of an earlier one still waiting" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-1", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-2", .Interactive));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-3", .Interactive));

    // Every interactive task goes on the head, so the most recent tap is served first and all of
    // them are still ahead of the background work.
    try expectIds(&.{ "interactive-3", "interactive-2", "interactive-1", "background-1" }, pendingTasks);
}

test "arrival order is kept among background tasks" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-1", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-2", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-3", .Background));

    try expectIds(&.{ "interactive-1", "background-1", "background-2", "background-3" }, pendingTasks);
}

test "an interactive task queued when nothing is waiting goes straight to the front" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));

    try expectIds(&.{"interactive-1"}, pendingTasks);
}

test "an interactive task goes on the head of a queue that holds nothing else" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-1", .Background));

    try expectIds(&.{ "interactive-1", "background-1" }, pendingTasks);
}

test "a background task never overtakes anything, whatever is already waiting" {
    const allocator = std.testing.allocator;
    var pendingTasks: std.ArrayList(ITask) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-1", .Background));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("interactive-1", .Interactive));
    try insertTaskByPriority(allocator, &pendingTasks, pendingTask("background-2", .Background));

    try expectIds(&.{ "interactive-1", "background-1", "background-2" }, pendingTasks);
}

//
// A pool's own record of a task, holding the ITask in a `task` field (like the Zig worker pools).
//
const IPoolRecord = struct {
    // The task.
    task: ITask,
};

test "insertTaskByPriority reads the priority of a pool's own record of a task" {
    const allocator = std.testing.allocator;
    var background: IPoolRecord = .{ .task = pendingTask("background-1", .Background) };
    var interactive: IPoolRecord = .{ .task = pendingTask("interactive-1", .Interactive) };
    var pendingTasks: std.ArrayList(*IPoolRecord) = .empty;
    defer pendingTasks.deinit(allocator);
    try insertTaskByPriority(allocator, &pendingTasks, &background);
    try insertTaskByPriority(allocator, &pendingTasks, &interactive);

    try std.testing.expectEqualStrings("interactive-1", pendingTasks.items[0].task.id);
    try std.testing.expectEqualStrings("background-1", pendingTasks.items[1].task.id);
}
