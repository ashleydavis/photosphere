import type { ITask, ITaskResult, IWorkerBackend, WorkerTaskCompletionCallback, TaskMessageCallback } from "task-queue";
import { TaskStatus } from "task-queue";

//
// Task message interface - all task messages must have a type field
//
interface ITaskMessage {
    type: string;
    [key: string]: any;
}

//
// WebSocket-based worker backend
// Communicates with dev-server via WebSocket to queue and execute tasks
//
export class WorkerBackendWebSocket implements IWorkerBackend {
    private ws: WebSocket;
    private activeTasksCount: number = 0;
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private workerAvailableCallbacks: (() => void)[] = [];

    // Initializes the WebSocket worker backend with a WebSocket connection
    constructor(ws: WebSocket) {
        this.ws = ws;
        this.setupMessageHandler();
    }

    // Sets up the WebSocket message event listener to handle incoming messages
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

    // Handles incoming WebSocket messages (task-completed and task-message)
    private handleMessage(message: any): void {
        if (message.type === "task-completed") {
            const { taskId, result } = message;
            
            this.activeTasksCount--;
            
            // Notify completion callbacks
            this.notifyCompletionCallbacks(result);
            
            // Notify that a worker is available
            this.notifyWorkerAvailable();
        }
        else if (message.type === "task-message") {
            const { taskId, message: taskMessage } = message;
            this.notifyMessageCallbacks(taskId, taskMessage);
        }
        else {
            throw new Error(`Unknown message type: ${message.type}`);
        }
    }

    //
    // Dispatch a task to the server via WebSocket.
    // Returns true if the task was dispatched, false if no worker was available.
    // For WebSocket, we always dispatch (server handles queuing).
    //
    dispatchTask(task: ITask<any>): boolean {
        this.activeTasksCount++;
        
        this.ws.send(JSON.stringify({
            type: "add-task",
            taskId: task.id,
            taskType: task.type,
            data: task.data,
        }));
        
        return true;
    }

    //
    // Registers a callback that will be called when a worker becomes available.
    //
    onWorkerAvailable(callback: () => void): void {
        this.workerAvailableCallbacks.push(callback);
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
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
    // Checks if all workers are idle (no active tasks).
    //
    isIdle(): boolean {
        return this.activeTasksCount === 0;
    }

    //
    // Shuts down the worker backend (no-op for WebSocket as connection may be shared).
    //
    shutdown(): void {
        // Don't close the WebSocket connection because we don't own it
    }

    //
    // Notifies callbacks of worker availability.
    //
    private notifyWorkerAvailable(): void {
        for (const callback of this.workerAvailableCallbacks) {
            callback();
        }
    }

    //
    // Invokes all registered completion callbacks with the task result.
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
    // Notifies all registered message callbacks that match the message type.
    //
    private async notifyMessageCallbacks(taskId: string, message: ITaskMessage): Promise<void> {
        const messageType = message.type;
        
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
}

