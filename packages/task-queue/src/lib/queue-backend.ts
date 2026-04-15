
//
// IQueueBackend — the interface that all task scheduling backends implement.
// Real worker pools (WorkerPoolBun, WorkerPoolElectronMain, WorkerPoolInline) and
// IPC/WebSocket proxies (ElectronQueueBackend, WebSocketQueueBackend) implement this.
// TaskQueue depends only on IQueueBackend; concrete backend classes are registered once
// at process startup via setQueueBackend().
//

import type { WorkerTaskCompletionCallback, TaskMessageCallback, UnsubscribeFn } from "./types";

//
// The interface implemented by all queue backends.
// Worker pools implement this plus IWorkerPool. IPC/WebSocket proxies implement only this.
//
export interface IQueueBackend {
    //
    // Adds a task to the backend. Returns the task ID.
    // If taskId is provided it is used instead of generating a new one.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string;

    //
    // Registers a callback that fires whenever a task with the given source is added.
    // Returns an unsubscribe function.
    //
    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn;

    //
    // Registers a callback that fires when any task completes (success or failure).
    // Returns an unsubscribe function.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn;

    //
    // Registers a callback for task messages of a specific type.
    // Returns an unsubscribe function.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn;

    //
    // Registers a callback for every task message regardless of type.
    // Returns an unsubscribe function.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn;

    //
    // Signals running tasks with the given source to cancel and drops any pending
    // tasks with that source from the queue.
    //
    cancelTasks(source: string): void;

    //
    // Registers a callback that fires when cancelTasks is called for the given source.
    // Returns an unsubscribe function.
    //
    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn;

    //
    // Shuts down the backend, releasing all resources.
    //
    shutdown(): void;
}

//
// The process-level singleton backend. Set once at startup via setQueueBackend().
//
let _backend: IQueueBackend | undefined;

//
// Registers the process-level singleton queue backend.
// Must be called once at process startup before any TaskQueue is created.
//
export function setQueueBackend(backend: IQueueBackend): void {
    _backend = backend;
}

//
// Returns the process-level singleton queue backend.
// Throws if setQueueBackend() has not been called.
//
export function getQueueBackend(): IQueueBackend {
    if (!_backend) {
        throw new Error("Queue backend not initialised — call setQueueBackend() at process startup.");
    }
    return _backend;
}
