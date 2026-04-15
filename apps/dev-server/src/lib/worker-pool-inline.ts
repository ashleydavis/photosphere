import type { ITask, ITaskResult, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, IQueueBackend, UnsubscribeFn } from "task-queue";
import { TaskStatus } from "task-queue";
import { executeTaskHandler } from "task-queue";
import type { ITaskContext } from "task-queue";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { randomUUID } from "node:crypto";
import { initTaskHandlers } from "api";

interface IBaseTaskContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}

// Represents a task that is currently executing.
interface IRunningTask {
    // The unique ID of the task.
    id: string;

    // The source (database path) that owns the task.
    source: string;

    // Set to true when cancelTasks is called for this task's source.
    cancelled: boolean;
}

//
// Inline worker pool that executes tasks directly without workers
// Supports up to maxConcurrent tasks running at once
//
export class WorkerPoolInline implements IQueueBackend {
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: IMessageCallbackEntry[] = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private maxConcurrent: number;
    private baseContext: IBaseTaskContext; //fio:

    // Tracks currently running tasks by ID so cancelTasks can mark them cancelled by source.
    private runningTasks: Map<string, IRunningTask> = new Map();

    // Tasks waiting to be executed when a slot opens up.
    private pendingTasks: ITask<any>[] = [];

    // Callbacks registered per source via onTaskAdded.
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    // Callbacks registered per source via onTasksCancelled.
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    // Initializes the inline worker pool with max concurrent tasks and working directory
    constructor(maxConcurrent: number, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, workerOptions: { verbose: boolean; sessionId: string }) {
        this.maxConcurrent = maxConcurrent;

        // Initialize task handlers
        initTaskHandlers();
        
        // Create base worker context (without sendMessage - that will be task-specific)
        // Note: We create our own context here instead of using initWorkerContext
        // because initWorkerContext sets up worker-specific logging which we don't need
        this.baseContext = {
            uuidGenerator: uuidGenerator,
            timestampProvider: timestampProvider,
            sessionId: workerOptions.sessionId,
        };
    }

    //
    // Adds a task to the queue. Executes immediately if a slot is available, otherwise queues it.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? randomUUID();
        const task: ITask<any> = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            source,
            createdAt: new Date(),
        };
        this.pendingTasks.push(task);

        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb(id);
            }
        }

        this.tryDispatchPending();
        return id;
    }

    //
    // Registers a callback that fires when a task with the given source is added.
    //
    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source);
        if (existing) {
            existing.push(callback);
        }
        else {
            this.taskAddedCallbacks.set(source, [callback]);
        }
        return () => {
            const cbs = this.taskAddedCallbacks.get(source);
            if (cbs) {
                const idx = cbs.indexOf(callback);
                if (idx !== -1) {
                    cbs.splice(idx, 1);
                }
            }
        };
    }

    //
    // Dispatches pending tasks up to the concurrency limit.
    //
    private tryDispatchPending(): void {
        while (this.pendingTasks.length > 0 && this.runningTasks.size < this.maxConcurrent) {
            const task = this.pendingTasks.shift()!;
            this.runningTasks.set(task.id, { id: task.id, source: task.source, cancelled: false });
            this.executeTask(task).catch((error) => {
                console.error(`Error executing task ${task.id}:`, error);
            });
        }
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): () => void {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): () => void {
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
    //
    onAnyTaskMessage(callback: TaskMessageCallback): () => void {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error: unknown) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : "";
        
        // Notify callbacks registered for specific message types
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }
            
            try {
                await callback({ taskId, message });
            }
            catch (error: unknown) {
                console.error("Error in task message callback:", error);
            }
        }
        
        // Notify callbacks registered for any message type
        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: unknown) {
                console.error("Error in any task message callback:", error);
            }
        }
    }

    //
    // Dispatches as many tasks a possible to workers.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    //
    // Executes a task inline and handles completion or failure
    //
    private async executeTask(task: ITask<any>): Promise<void> {
        try {
            // Create a task-specific sendMessage function that captures the task ID in a closure
            // This ensures each concurrent task routes messages correctly without race conditions
            const taskSpecificSendMessage = (message: any): void => {
                this.notifyMessageCallbacks(task.id, message).catch((error) => {
                    console.error("Error notifying message callbacks:", error);
                });
            };

            const taskContextWithSendMessage: ITaskContext = {
                ...this.baseContext,
                sendMessage: taskSpecificSendMessage,
                isCancelled: (): boolean => this.runningTasks.get(task.id)?.cancelled ?? false,
                taskId: task.id,
            };

            const outputs = await executeTaskHandler(task.type, task.data, taskContextWithSendMessage);

            const result: ITaskResult = {
                status: TaskStatus.Succeeded,
                outputs,
                taskId: task.id,
                type: task.type,
                inputs: task.data,
            };

            this.runningTasks.delete(task.id);
            await this.notifyCompletionCallbacks(result);
            this.tryDispatchPending();
        }
        catch (error: any) {
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
                taskId: task.id,
                type: task.type,
                inputs: task.data,
            };

            this.runningTasks.delete(task.id);
            await this.notifyCompletionCallbacks(result);
            this.tryDispatchPending();
        }
    }

    //
    // Signals running tasks with the given source to cancel, drops pending tasks, and fires cancellation callbacks.
    //
    cancelTasks(source: string): void {
        this.pendingTasks = this.pendingTasks.filter(task => task.source !== source);
        for (const runningTask of this.runningTasks.values()) {
            if (runningTask.source === source) {
                runningTask.cancelled = true;
            }
        }

        const callbacks = this.tasksCancelledCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb();
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
            const cbs = this.tasksCancelledCallbacks.get(source);
            if (cbs) {
                const idx = cbs.indexOf(callback);
                if (idx !== -1) {
                    cbs.splice(idx, 1);
                }
            }
        };
    }

    //
    // Shuts down the worker pool (no-op for inline execution)
    //
    shutdown(): void {
        // Nothing to shut down for inline execution
    }
}

