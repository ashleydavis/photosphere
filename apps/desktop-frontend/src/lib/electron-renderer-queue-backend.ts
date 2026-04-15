import type { ITaskResult, IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn } from "task-queue";
import type { IElectronAPI } from "electron-defs";

//
// Task completion response from Electron main process
//
interface ITaskCompletionResponse {
    // The ID of the completed task.
    taskId: string;

    // The result of the completed task.
    result: ITaskResult;
}

//
// Task message data from Electron main process
//
interface ITaskMessageData {
    // The ID of the task that sent the message.
    taskId: string;

    // The message payload sent by the task.
    message: any;
}

//
// Electron IPC-based queue backend.
// Forwards task dispatch and completion to the Electron main process via IPC.
// The renderer process has no workers of its own — this class is purely a proxy.
//
export class ElectronRendererQueueBackend implements IQueueBackend {
    //
    // The Electron IPC bridge injected by the preload script.
    //
    private electronAPI: IElectronAPI;

    //
    // Callbacks registered for task completion.
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    //
    // Callbacks registered for specific task message types.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks registered for all task messages regardless of type.
    //
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Per-source callbacks fired when a task is added via addTask.
    //
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    //
    // Per-source callbacks fired when cancelTasks is called for that source.
    //
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    //
    // Creates a new Electron renderer backend that communicates with the main process via IPC.
    //
    constructor(electronAPI: IElectronAPI) {
        this.electronAPI = electronAPI;
        this.setupMessageHandlers();
    }

    //
    // Sets up IPC message handlers for task completion and task messages.
    //
    private setupMessageHandlers(): void {
        this.electronAPI.onMessage('task-completed', data => {
            this.handleTaskCompleted(data as ITaskCompletionResponse);
        });

        this.electronAPI.onMessage('task-message', data => {
            const { taskId, message } = data as ITaskMessageData;
            this.notifyMessageCallbacks(taskId, message);
        });
    }

    //
    // Registers a callback that fires whenever any task completes.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn { //todo: is there any way to make this an ISubscription object?
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback for task messages of a specific type.
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
    // Registers a callback for all task messages regardless of type.
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
    // Registers a callback fired when a task with the given source is added.
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
    // Forwards a task to the Electron main process via IPC and fires onTaskAdded callbacks.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? crypto.randomUUID();
        this.electronAPI.addTask(type, data, source, id);
        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb(id);
            }
        }
        return id;
    }

    //
    // Forwards the cancel signal to the main process via IPC and fires local cancellation callbacks.
    //
    cancelTasks(source: string): void {
        this.electronAPI.cancelTasks(source);
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
    // Handles a task-completed message from the main process.
    //
    private handleTaskCompleted(data: ITaskCompletionResponse): void {
        this.notifyCompletionCallbacks(data.result);
    }

    //
    // Invokes all registered completion callbacks.
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
    // Invokes message callbacks matching the message type.
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
    // Removes all IPC listeners. Call when the queue is no longer needed.
    //
    shutdown(): void {
        this.electronAPI.removeAllListeners('task-completed');
        this.electronAPI.removeAllListeners('task-message');
    }
}
