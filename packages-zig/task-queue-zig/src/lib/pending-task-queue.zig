//
// The ordering rules every queue backend applies to its pending tasks.
//
// They live here, apart from the pools that use them, because all three desktop pools (Bun,
// Electron main and the dev-server's inline pool) have to agree on them, and because ordering is
// exactly the kind of thing that is easy to get subtly wrong and easy to test in isolation. The
// native Android and iOS pools apply the same two rules in their own languages.
//
// There is one queue, not one per priority. An interactive task goes on the head of it and a
// background task on the end, and the pool always takes from the head. That is the whole of the
// mechanism.
//

const std = @import("std");
const types = @import("types.zig");
const TaskPriority = types.TaskPriority;
const DEFAULT_TASK_PRIORITY = types.DEFAULT_TASK_PRIORITY;

//
// Works out what priority a task actually runs at.
//
// A priority the caller asked for always wins, which is what lets a long-running child (a whole
// database prefetch, say) opt back down to background even though the task that started it was
// something the user was waiting on. Otherwise a task queued from inside a running task runs at its
// parent's priority, so an import's hash and upload children can never overtake a tap. Anything
// else, which is every task queued from the user interface, runs at the default.
//
pub fn resolveTaskPriority(requested: ?TaskPriority, parentPriority: ?TaskPriority) TaskPriority {
    if (requested) |requestedPriority| {
        return requestedPriority;
    }
    if (parentPriority) |parentTaskPriority| {
        return parentTaskPriority;
    }
    return DEFAULT_TASK_PRIORITY;
}

//
// Gets the priority of a pending task: an ITask, a pointer to one, or a pointer to a pool's own
// record of a task that holds the ITask in a `task` field. (No TypeScript counterpart: TypeScript
// pools keep ITask objects in their pending queue, Zig pools keep their own records.)
//
fn priorityOf(task: anytype) TaskPriority {
    const TaskT = @TypeOf(task);
    const StructT = switch (@typeInfo(TaskT)) {
        .pointer => |pointer_info| pointer_info.child,
        else => TaskT,
    };
    if (@hasField(StructT, "priority")) {
        return task.priority;
    }
    return task.task.priority;
}

//
// Puts a task into the one pending queue: an interactive task on the head, a background task on the
// end. The pool takes from the head, so a tap is dispatched before everything already waiting.
//
// A second interactive task therefore goes in front of the first one still waiting, rather than
// behind it. Background tasks keep their arrival order, because they only ever go on the end.
//
pub fn insertTaskByPriority(allocator: std.mem.Allocator, pendingTasks: anytype, task: anytype) !void {
    if (priorityOf(task) == .Interactive) {
        try pendingTasks.insert(allocator, 0, task);
    }
    else {
        try pendingTasks.append(allocator, task);
    }
}
