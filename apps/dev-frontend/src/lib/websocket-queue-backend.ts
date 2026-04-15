import type { ITaskResult, IQueueBackend, WorkerTaskCompletionCallback, TaskMessageCallback, IMessageCallbackEntry, UnsubscribeFn } from "task-queue";

//
// WebSocket-based queue backend.
// Forwards task dispatch and completion to the dev-server via WebSocket.
// The frontend has no workers of its own — this class is purely a proxy.
//
export class WebSocketQueueBackend implements IQueueBackend {
    //
    // The underlying WebSocket connection.
    //
    private ws: WebSocket;

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
    // Creates a new WebSocket queue backend with the given connection.
    //
    constructor(ws: WebSocket) {
        this.ws = ws;
        this.setupMessageHandler();
    }

    //
    // Sets up the WebSocket message event listener.
    //
    private setupMessageHandler(): void {
        this.ws.addEventListener("message", (event) => {
            try {
                const message = JSON.parse(event.data);
                this.handleMessage(message);
            }
            catch (error) {
                console.error("Failed to parse WebSocket message:", error);
            }
        });
    }

    //
    // Handles incoming WebSocket messages (task-completed and task-message).
    //
    private handleMessage(message: any): void {
        if (message.type === "task-completed") {
            const result = message.result as ITaskResult;
            this.notifyCompletionCallbacks(result);
        }
        else if (message.type === "task-message") {
            const { taskId, message: taskMessage } = message;
            this.notifyMessageCallbacks(taskId, taskMessage);
        }
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
    // Sends a task to the server via WebSocket and fires onTaskAdded callbacks.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? crypto.randomUUID();
        this.ws.send(JSON.stringify({
            type: "add-task",
            taskId: id,
            taskType: type,
            data,
            source,
        }));
        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb(id);
            }
        }
        return id;
    }

    //
    // Sends a cancel-tasks message to the server and fires local cancellation callbacks.
    //
    cancelTasks(source: string): void {
        this.ws.send(JSON.stringify({ type: "cancel-tasks", source }));
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
    // No-op: the WebSocket connection is owned by the caller.
    //
    shutdown(): void {
        // Don't close the WebSocket — we don't own it
    }

    //
    // Invokes all registered completion callbacks.
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
}
