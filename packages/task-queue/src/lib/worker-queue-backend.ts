//
// Worker-side queue backend for use inside worker processes (Bun workers or Electron utility processes).
// Dispatches child tasks to the main process/thread via a provided postMessage function and
// fires completion callbacks when "task-completed" messages are forwarded back by the main process.
//

import { randomUUID } from "node:crypto";
import type { IQueueBackend } from "./queue-backend";
import type { ITaskResult, WorkerTaskCompletionCallback, TaskMessageCallback, UnsubscribeFn, IMessageCallbackEntry } from "./types";

//
// IQueueBackend implementation for worker processes.
// addTask() sends a "queue-task" message to the main process via postMessage.
// notifyTaskCompleted() is called by the worker message handler when the main
// process forwards a "task-completed" message back for a child task.
//
export class WorkerQueueBackend implements IQueueBackend {
    //
    // Function used to send messages to the main process or thread.
    //
    private postMessage: (message: any) => void;

    //
    // Callbacks invoked when any child task completes.
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    //
    // Callbacks invoked for task messages of a specific type.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks invoked for all task messages regardless of type.
    //
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Per-source callbacks fired when addTask is called for that source.
    //
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    //
    // Per-source callbacks fired when cancelTasks is called for that source.
    //
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    constructor(postMessage: (message: any) => void) {
        this.postMessage = postMessage;
    }

    //
    // Sends a "queue-task" message to the main process and fires onTaskAdded callbacks.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? randomUUID();
        this.postMessage({ type: "queue-task", taskId: id, taskType: type, data, source });
        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }
        return id;
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source) ?? [];
        existing.push(callback);
        this.taskAddedCallbacks.set(source, existing);
        return () => {
            const callbacks = this.taskAddedCallbacks.get(source);
            if (callbacks) {
                const idx = callbacks.indexOf(callback);
                if (idx !== -1) {
                    callbacks.splice(idx, 1);
                }
            }
        };
    }

    //
    // Registers a callback that fires when any child task completes.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(callback);
        return () => {
            const idx = this.completionCallbacks.indexOf(callback);
            if (idx !== -1) {
                this.completionCallbacks.splice(idx, 1);
            }
        };
    }

    //
    // Registers a callback for child task messages of a specific type.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn {
        const entry = { messageType, callback };
        this.messageCallbacks.push(entry);
        return () => {
            const idx = this.messageCallbacks.indexOf(entry);
            if (idx !== -1) {
                this.messageCallbacks.splice(idx, 1);
            }
        };
    }

    //
    // Registers a callback for all child task messages regardless of type.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const idx = this.anyMessageCallbacks.indexOf(callback);
            if (idx !== -1) {
                this.anyMessageCallbacks.splice(idx, 1);
            }
        };
    }

    //
    // Fires onTasksCancelled callbacks for the given source.
    // Called when the main process sends a "cancel-tasks" message to this worker.
    //
    cancelTasks(source: string): void {
        const callbacks = this.tasksCancelledCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback();
            }
        }
    }

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    //
    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn {
        const existing = this.tasksCancelledCallbacks.get(source) ?? [];
        existing.push(callback);
        this.tasksCancelledCallbacks.set(source, existing);
        return () => {
            const callbacks = this.tasksCancelledCallbacks.get(source);
            if (callbacks) {
                const idx = callbacks.indexOf(callback);
                if (idx !== -1) {
                    callbacks.splice(idx, 1);
                }
            }
        };
    }

    //
    // No-op: the worker process lifecycle is managed externally.
    //
    shutdown(): void {}

    //
    // Fires all registered onTaskComplete callbacks with the given result.
    // Called by the worker message handler when the main process forwards a "task-completed" message.
    //
    async notifyTaskCompleted(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            await callback(result);
        }
    }

    //
    // Fires all registered onTaskMessage / onAnyTaskMessage callbacks.
    // Called by the worker message handler when the main process forwards a "task-message" back
    // to this worker for a child task it dispatched.
    //
    async notifyTaskMessage(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;

        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }
            await callback({ taskId, message });
        }

        for (const callback of this.anyMessageCallbacks) {
            await callback({ taskId, message });
        }
    }
}
