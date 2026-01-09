import type { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback } from "task-queue";
import type { IElectronAPI } from "electron-defs";

//
// Task completion response from Electron main process
//
interface ITaskCompletionResponse {
    taskId: string;
    result: ITaskResult;
}

//
// Task message data from Electron main process
//
interface ITaskMessageData {
    taskId: string;
    message: any;
}

//
// Electron IPC-based worker backend implementation
// Communicates with Electron main process via IPC to queue and execute tasks
//
export class WorkerBackendElectronRenderer implements IWorkerBackend {
    private electronAPI: IElectronAPI;
    private workerAvailableCallbacks: (() => void)[] = [];
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private activeTasksCount: number = 0;

    //
    // Creates a new Electron renderer worker backend that communicates with the main process via IPC.
    //
    constructor(electronAPI: IElectronAPI) {
        this.electronAPI = electronAPI;
        this.setupMessageHandlers();
    }

    //
    // Internal: Sets up IPC message handlers for task completion and task messages.
    //
    private setupMessageHandlers(): void {
        // Listen for task completion messages
        this.electronAPI.onMessage('task-completed', data => {
            this.handleTaskCompleted(data);
        });

        // Listen for task messages
        this.electronAPI.onMessage('task-message', data => {
            const { taskId, message } = data as ITaskMessageData;
            this.notifyMessageCallbacks(taskId, message);
        });
    }

    //
    // Gets a summary of the worker pool.
    //
    getStatus() {
        return {
            peakWorkers: 1 // Electron IPC is single-threaded from renderer perspective
        };
    }

    //
    // Registers a callback that will be called when a worker becomes available.
    //
    onWorkerAvailable(callback: () => void): void {
        this.workerAvailableCallbacks.push(callback);
        // In renderer, we always have a "worker" available (the IPC connection)
        // So we can immediately notify
        callback();
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
    // Internal: Handles task completion messages from the main process.
    // Updates statistics, resolves pending promises, and notifies callbacks.
    //
    private handleTaskCompleted(data: ITaskCompletionResponse): void {
        const { taskId, result } = data;

        if (this.activeTasksCount > 0) {
            this.activeTasksCount--;
        }
        
        this.notifyCompletionCallbacks(result);
        this.notifyWorkerAvailable();
    }

    //
    // Internal: Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {
        for (const callback of this.completionCallbacks) {
            try {
                await callback(result);
            }
            catch (error: any) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Internal: Invokes all registered message callbacks with the task message.
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
                console.error("Error in task message callback:", error);
            }
        }
        
        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                console.error("Error in any task message callback:", error);
            }
        }
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
    // Dispatches as many tasks a possible to workers.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    dispatchTask(task: ITask<any>): boolean {
        // In renderer, we always dispatch via IPC (no real workers)
        this.activeTasksCount++;
        this.electronAPI.addTask(task.type, task.data, task.id);
        return true;
    }

    //
    // Checks if all workers are idle.
    //
    isIdle(): boolean {
        return this.activeTasksCount === 0;
    }

    //
    // Shuts down the worker backend and cleans up resources.
    // Removes all IPC message listeners and should be called when the queue is no longer needed.
    //
    shutdown(): void {
        // Cleanup message listeners
        this.electronAPI.removeAllListeners('task-completed');
        this.electronAPI.removeAllListeners('task-message');
    }
}

