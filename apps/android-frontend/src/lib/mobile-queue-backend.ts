import type { IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, UnsubscribeFn } from "task-queue";

//
// No-op queue backend for mobile.
// Mobile background task execution is not yet implemented, so this backend
// accepts tasks but never runs them and never fires completion or message
// callbacks. It exists only so the UI can mount and reach the About page.
//
export class MobileQueueBackend implements IQueueBackend {
    //
    // Accepts a task but does not run it. Mobile has no worker yet, so the task
    // is dropped. Returns the supplied taskId, or a generated id when none is given.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        return taskId ?? crypto.randomUUID();
    }

    //
    // Registers a task-added callback. No tasks ever run on mobile yet, so the
    // callback is never invoked; a no-op unsubscribe function is returned.
    //
    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        return () => {};
    }

    //
    // Registers a task-completion callback. No tasks ever complete on mobile yet,
    // so the callback is never invoked; a no-op unsubscribe function is returned.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        return () => {};
    }

    //
    // Registers a typed task-message callback. No task messages are produced on
    // mobile yet, so the callback is never invoked; a no-op unsubscribe is returned.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn {
        return () => {};
    }

    //
    // Registers an any-message callback. No task messages are produced on mobile
    // yet, so the callback is never invoked; a no-op unsubscribe is returned.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        return () => {};
    }

    //
    // No-op: there are no tasks to cancel on mobile yet.
    //
    cancelTasks(source: string): void {
    }

    //
    // Registers a tasks-cancelled callback. Cancellation is a no-op on mobile yet,
    // so the callback is never invoked; a no-op unsubscribe function is returned.
    //
    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn {
        return () => {};
    }

    //
    // No-op: there is no worker or resource to release on mobile yet.
    //
    shutdown(): void {
    }
}
