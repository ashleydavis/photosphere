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

import { DEFAULT_TASK_PRIORITY, TaskPriority } from "./types";
import type { ITask } from "./types";

//
// Works out what priority a task actually runs at.
//
// A priority the caller asked for always wins, which is what lets a long-running child (a whole
// database prefetch, say) opt back down to background even though the task that started it was
// something the user was waiting on. Otherwise a task queued from inside a running task runs at its
// parent's priority, so an import's hash and upload children can never overtake a tap. Anything
// else, which is every task queued from the user interface, runs at the default.
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
// A second interactive task therefore goes in front of the first one still waiting, rather than
// behind it. Background tasks keep their arrival order, because they only ever go on the end.
//
export function insertTaskByPriority(pendingTasks: ITask<any>[], task: ITask<any>): void {
    if (task.priority === TaskPriority.Interactive) {
        pendingTasks.unshift(task);
    }
    else {
        pendingTasks.push(task);
    }
}
