import type { ITaskResult, IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn, TaskPriority } from "task-queue";
import type { IJsonValue, IZiggyBridge } from "ziggy-bridge";

//
// Task completion event from the core.
//
interface ITaskCompletionResponse {
    // The ID of the completed task.
    taskId: string;

    // The result of the completed task.
    result: ITaskResult;
}

//
// Task message event from the core.
//
interface ITaskMessageData {
    // The ID of the task that sent the message.
    taskId: string;

    // The message payload sent by the task.
    message: IJsonValue;
}

//
// Ziggy bridge-based queue backend.
// Forwards task dispatch and completion to the core over window.ziggy.
// The page has no workers of its own: this class is purely a proxy.
//
export class ZiggyQueueBackend implements IQueueBackend {
    //
    // The bridge the shell injects into the page.
    //
    private ziggy: IZiggyBridge;

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
    // Creates a new backend that communicates with the core over the bridge.
    //
    constructor(ziggy: IZiggyBridge) {
        this.ziggy = ziggy;
        this.setupMessageHandlers();
    }

    //
    // Sets up bridge listeners for task completion and task messages.
    //
    private setupMessageHandlers(): void {
        this.ziggy.onMessage<ITaskCompletionResponse>('task-completed', data => {
            this.handleTaskCompleted(data);
        });

        this.ziggy.onMessage<ITaskMessageData>('task-message', data => {
            this.notifyMessageCallbacks(data.taskId, data.message);
        });
    }

    //
    // Registers a callback that fires whenever any task completes.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
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
            const callbacks = this.taskAddedCallbacks.get(source);
            if (callbacks) {
                const index = callbacks.indexOf(callback);
                if (index !== -1) {
                    callbacks.splice(index, 1);
                }
            }
        };
    }

    //
    // Forwards a task to the core and fires onTaskAdded callbacks. The priority is sent as its text,
    // "interactive" or "background", and left out when the task has none, which the core runs as background.
    //
    addTask(type: string, data: IJsonValue, source: string, taskId?: string, priority?: TaskPriority): string {
        const id = taskId ?? crypto.randomUUID();
        this.ziggy.send('add-task', {
            taskType: type,
            data,
            source,
            taskId: id,
            priority: priority ?? null,
        });
        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const callback of callbacks) {
                callback(id);
            }
        }
        return id;
    }

    //
    // Forwards the cancel signal to the core (the source as a bare string) and fires local cancellation callbacks.
    //
    cancelTasks(source: string): void {
        this.ziggy.send('cancel-tasks', source);
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
                const index = callbacks.indexOf(callback);
                if (index !== -1) {
                    callbacks.splice(index, 1);
                }
            }
        };
    }

    //
    // Handles a task-completed event from the core.
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
            catch (error) {
                console.error("Error in task completion callback:", error);
            }
        }
    }

    //
    // Invokes message callbacks matching the message type.
    //
    private async notifyMessageCallbacks(taskId: string, message: IJsonValue): Promise<void> {
        const messageType = taskMessageType(message);

        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }

            try {
                await callback({ taskId, message });
            }
            catch (error) {
                console.error("Error in task message callback:", error);
            }
        }

        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error) {
                console.error("Error in any task message callback:", error);
            }
        }
    }

    //
    // Removes all bridge listeners. Call when the queue is no longer needed.
    //
    shutdown(): void {
        this.ziggy.removeAllListeners('task-completed');
        this.ziggy.removeAllListeners('task-message');
    }
}

//
// The type a task message declares in its "type" field, or undefined for a message that is not an object or has no such field.
//
function taskMessageType(message: IJsonValue): IJsonValue | undefined {
    if (message === null || typeof message !== "object" || Array.isArray(message)) {
        return undefined;
    }
    return message.type;
}
