import { IUuidGenerator, log } from "utils";
import { ITaskResult, TaskMessageCallback, UnsubscribeFn, IMessageCallbackEntry, TaskCompletionCallback } from "./types";
import { IQueueBackend, getQueueBackend } from "./queue-backend";

//
// Task queue interface
//
export interface ITaskQueue {
    //
    // Adds a task to the queue to be run. Returns uuid of the task.
    // If taskId is provided, it will be used instead of generating a new one.
    //
    addTask(type: string, data: any, taskId?: string): string;

    //
    // Resolves when all currently in-flight tasks have completed.
    // Resolves immediately if no tasks are in flight.
    //
    awaitAllTasks(): Promise<void>;

    //
    // Resolves when the task with the given ID completes.
    //
    awaitTask(taskId: string): Promise<void>;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    // Returns an unsubscribe function to remove the callback.
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): UnsubscribeFn;

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // The callback receives the task ID and the message data.
    // Only messages with the specified messageType will be passed to the callback.
    // Returns an unsubscribe function to remove the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn;

    //
    // Registers a callback that will be called for any task message, regardless of type.
    // The callback receives the task ID and the message data.
    // Returns an unsubscribe function to remove the callback.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn;

    //
    // Shuts down the task queue and its worker pool, terminating any running tasks.
    // Should only be called when the queue is no longer needed (e.g. app exit, connection close).
    //
    shutdown(): void;
}

//
// Generic task queue implementation with an abstraction for workers.
//
export class TaskQueue implements ITaskQueue {
    //
    // Generates unique IDs for tasks added via addTask.
    //
    private uuidGenerator: IUuidGenerator;

    //
    // Source tag used to identify all tasks owned by this queue instance.
    // Used for filtering completions and for cancellation via shutdown().
    //
    private source: string;

    //
    // The underlying backend that executes tasks (worker pool or IPC proxy).
    //
    private backend: IQueueBackend;

    //
    // Callbacks invoked whenever a tracked task completes (success or failure).
    //
    private completionCallbacks: TaskCompletionCallback<any>[] = [];

    //
    // Callbacks invoked when a tracked task emits a message of a specific type.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks invoked when a tracked task emits any message.
    //
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Count of tasks that have been added but not yet completed.
    //
    private numTasksInFlight: number = 0;

    //
    // Set of task IDs owned by this queue, used to filter backend callbacks.
    //
    private trackedTaskIds: Set<string> = new Set();

    //
    // Resolve functions for awaitAllTasks() callers, drained when numTasksInFlight reaches zero.
    //
    private awaitAllResolvers: (() => void)[] = [];

    //
    // Resolve functions for awaitTask(taskId) callers, keyed by task ID.
    //
    private awaitTaskResolvers: Map<string, (() => void)[]> = new Map();

    //
    // Unsubscribe functions returned by backend subscriptions, called on shutdown.
    //
    private unsubscribeFunctions: UnsubscribeFn[] = [];

    constructor(uuidGenerator: IUuidGenerator, source: string) {
        this.uuidGenerator = uuidGenerator;
        this.source = source;
        this.backend = getQueueBackend();
        this.unsubscribeFunctions.push(
            this.backend.onTaskAdded(this.source, (taskId: string) => {
                this.trackedTaskIds.add(taskId);
                this.numTasksInFlight++;
            })
        );
        this.unsubscribeFunctions.push(
            this.backend.onTaskComplete((result: ITaskResult) => {
                if (!this.trackedTaskIds.has(result.taskId)) {
                    return;
                }
                this.notifyCompletionCallbacks(result);
            })
        );
        this.unsubscribeFunctions.push(
            this.backend.onAnyTaskMessage(message => {
                if (!this.trackedTaskIds.has(message.taskId)) {
                    return;
                }
                this.notifyMessageCallbacks(message.taskId, message.message);
            })
        );
        this.unsubscribeFunctions.push(
            this.backend.onTasksCancelled(this.source, () => {
                this.resolveAllWaiters();
            })
        );
    }

    //
    // Resolves all pending awaitAllTasks() and awaitTask() callers immediately.
    //
    private resolveAllWaiters(): void {
        for (const resolve of this.awaitAllResolvers) {
            resolve();
        }
        this.awaitAllResolvers = [];

        for (const resolvers of this.awaitTaskResolvers.values()) {
            for (const resolve of resolvers) {
                resolve();
            }
        }
        this.awaitTaskResolvers.clear();
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    //
    addTask(type: string, data: any, taskId?: string): string {
        const id = taskId || this.uuidGenerator.generate();
        this.backend.addTask(type, data, this.source, id);
        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    // Returns an unsubscribe function to remove the callback.
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): UnsubscribeFn {
        const cb = callback as TaskCompletionCallback<any, any>;
        this.completionCallbacks.push(cb);
        return () => {
            const index = this.completionCallbacks.indexOf(cb);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    // Returns an unsubscribe function to remove the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn {
        const entry = { messageType, callback };
        this.messageCallbacks.push(entry);
        return () => {
            const index = this.messageCallbacks.indexOf(entry);
            if (index !== -1) {
                this.messageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    // Returns an unsubscribe function to remove the callback.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Resolves when all currently in-flight tasks have completed.
    // Resolves immediately if no tasks are in flight.
    //
    awaitAllTasks(): Promise<void> {
        if (this.numTasksInFlight <= 0) {
            return Promise.resolve();
        }
        return new Promise<void>(resolve => {
            this.awaitAllResolvers.push(resolve);
        });
    }

    //
    // Resolves when the task with the given ID completes.
    //
    awaitTask(taskId: string): Promise<void> {
        if (!this.trackedTaskIds.has(taskId)) {
            return Promise.resolve();
        }
        return new Promise<void>(resolve => {
            const existing = this.awaitTaskResolvers.get(taskId);
            if (existing) {
                existing.push(resolve);
            }
            else {
                this.awaitTaskResolvers.set(taskId, [resolve]);
            }
        });
    }

    //
    // Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        this.trackedTaskIds.delete(result.taskId);
        this.numTasksInFlight--;

        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error: any) {
                log.exception("Error in task completion callback", error);
            }
        }

        // Resolve awaitTask waiters for this task ID.
        const taskResolvers = this.awaitTaskResolvers.get(result.taskId);
        if (taskResolvers) {
            for (const resolve of taskResolvers) {
                resolve();
            }
            this.awaitTaskResolvers.delete(result.taskId);
        }

        // Resolve awaitAll waiters if all tasks are done.
        if (this.numTasksInFlight <= 0) {
            for (const resolve of this.awaitAllResolvers) {
                resolve();
            }
            this.awaitAllResolvers = [];
        }
    }

    //
    // Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;

        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }
            
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                log.exception("Error in task message callback", error);
            }
        }

        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                log.exception("Error in any task message callback", error);
            }
        }
    }

    //
    // Cancels all in-flight tasks belonging to this queue and cleans up subscriptions.
    // Any callers blocked in awaitAllTasks() or awaitTask() are resolved immediately.
    //
    shutdown(): void {
        this.backend.cancelTasks(this.source);

        for (const unsubscribe of this.unsubscribeFunctions) {
            unsubscribe();
        }
        this.unsubscribeFunctions = [];

        this.trackedTaskIds.clear();
        this.resolveAllWaiters();
        this.messageCallbacks = [];
        this.anyMessageCallbacks = [];
        this.completionCallbacks = [];
    }
}



