import type { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback } from "task-queue";
import { TaskStatus } from "task-queue";
import { executeTaskHandler } from "task-queue";
import type { ITaskContext } from "task-queue";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { initTaskHandlers } from "api";

interface IBaseTaskContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}

//
// Inline worker backend that executes tasks directly without workers
// Supports up to maxConcurrent tasks running at once
//
export class WorkerBackendInline implements IWorkerBackend {
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private workerAvailableCallbacks: (() => void)[] = [];
    private maxConcurrent: number;
    private tasksRunning: number = 0;
    private baseContext: IBaseTaskContext;

    // Initializes the inline worker backend with max concurrent tasks and working directory
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
    // Gets a summary of the worker pool.
    //
    getStatus() {
        return {
            peakWorkers: this.maxConcurrent
        };
    }

    //
    // Registers a callback that will be called when a worker becomes available.
    //
    onWorkerAvailable(callback: () => void): void {
        this.workerAvailableCallbacks.push(callback);
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): void {
        this.completionCallbacks.push(callback);
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): void {
        this.messageCallbacks.push({ messageType, callback });
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): void {
        this.anyMessageCallbacks.push(callback);
    }

    //
    // Notifies callback of worker availability.
    //
    private notifyWorkerAvailable(): void {
        for (const callback of this.workerAvailableCallbacks) {
            callback();
        }
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
    dispatchTask(task: ITask<any>): boolean {
        if (this.tasksRunning >= this.maxConcurrent) {
            // The maximum number of concurrent tasks is reached, so we don't process any more tasks yet.
            return false;
        }

        // Mark task as running
        this.tasksRunning++;

        // Execute task inline
        this.executeTask(task).catch((error) => {
            console.error(`Error executing task ${task.id}:`, error);
        });

        return true;
    }

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

            // Create a task-specific context with the task-specific sendMessage
            const taskContextWithSendMessage: ITaskContext = {
                ...this.baseContext,
                sendMessage: taskSpecificSendMessage,
            };

            const outputs = await executeTaskHandler(task.type, task.data, taskContextWithSendMessage);

            // Task completed successfully
            const result: ITaskResult = {
                status: TaskStatus.Succeeded,
                outputs,
                taskId: task.id,
            };

            this.tasksRunning--;
            await this.notifyCompletionCallbacks(result);
            this.notifyWorkerAvailable();
        }
        catch (error: any) {
            // Task failed
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
                taskId: task.id,
            };

            this.tasksRunning--;
            await this.notifyCompletionCallbacks(result);
            this.notifyWorkerAvailable();
        }
    }

    //
    // Checks if all workers are idle.
    //
    isIdle(): boolean {
        return this.tasksRunning === 0;
    }

    //
    // Shuts down the worker backend (no-op for inline execution)
    //
    shutdown(): void {
        // Nothing to shut down for inline execution
    }
}

