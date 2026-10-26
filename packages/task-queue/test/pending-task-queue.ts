//
// The ordering rules MockWorkerPool applies to its pending tasks, the rules the app's queue backend
// applies, so the TaskQueue tests see tasks dispatched in the order the app dispatches them.
//
// There is one queue, not one per priority. An interactive task goes on the head of it and a
// background task on the end, and the pool always takes from the head.
//

import { DEFAULT_TASK_PRIORITY, TaskPriority } from "../src/lib/types";
import type { ITask } from "../src/lib/types";

//
// Works out what priority a task actually runs at.
//
// A priority the caller asked for always wins. Otherwise a task queued from inside a running task
// runs at its parent's priority, so a child can never overtake a tap. Anything else runs at the
// default.
//
export function resolveTaskPriority(requested: TaskPriority | undefined, parentPriority: TaskPriority | undefined): TaskPriority {
    if (requested !== undefined) {
        return requested;
    }
    if (parentPriority !== undefined) {
        return parentPriority;
    }
    return DEFAULT_TASK_PRIORITY;
}

//
// Puts a task into the one pending queue: an interactive task on the head, a background task on the
// end. The pool takes from the head, so a tap is dispatched before everything already waiting.
//
export function insertTaskByPriority(pendingTasks: ITask<any>[], task: ITask<any>): void {
    if (task.priority === TaskPriority.Interactive) {
        pendingTasks.unshift(task);
    }
    else {
        pendingTasks.push(task);
    }
}
