import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { v4 as uuidv4 } from "uuid";

//
// Task message interface - all task messages must have a type field
//
interface ITaskMessage {
    type: string;
    [key: string]: any;
}

//
// WebSocket-based task queue implementation
// Communicates with dev-server via WebSocket to queue and execute tasks
//
export class TaskQueueWebSocket implements ITaskQueue {
    private ws: WebSocket;
    private activeTasksCount: number = 0;
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback<any> }> = [];
    private anyMessageCallbacks: TaskMessageCallback<any>[] = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;
    private allTasksResolvers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

    // Initializes the WebSocket task queue with a WebSocket connection
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
            
            if (!result.taskType) {
                throw new Error(`Task result missing taskType for task ${taskId}`);
            }
            
            const taskType = result.taskType;
            
            if (result.status === TaskStatus.Completed) {
                this.tasksCompleted++;
                console.log(`[TaskQueue] Task completed: ${taskId} (type: ${taskType})`);
            }
            else if (result.status === TaskStatus.Failed) {
                this.tasksFailed++;
                const errorMessage = result.errorMessage || "Unknown error";
                console.log(`[TaskQueue] Task failed: ${taskId} (type: ${taskType}, error: ${errorMessage})`);
            }
            
            this.notifyCompletionCallbacks(result);
            this.checkAllTasksComplete();
        }
        else if (message.type === "task-message") {
            const { taskId, message: taskMessage } = message;
            this.notifyMessageCallbacks(taskId, taskMessage);
        }
        else {
            throw new Error(`Unknown message type: ${message.type}`);
        }
    }

    // Queues a task by sending it to the server via WebSocket
    addTask(type: string, data: any, taskId?: string): string {
        const finalTaskId = taskId || uuidv4();
        this.tasksQueued++;
        this.activeTasksCount++;
        
        this.ws.send(JSON.stringify({
            type: "add-task",
            taskId: finalTaskId,
            taskType: type,
            data,
        }));
        
        return finalTaskId;
    }

    // Registers a callback to be invoked when any task completes
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    // Adds a task and waits for its completion, returning the result
    async awaitTask<TInputs = any, TOutputs = any>(type: string, data: TInputs): Promise<TOutputs> {
        const taskId = this.addTask(type, data);

        return new Promise<TOutputs>((resolve, reject) => {
            let resolved = false;

            const resolveOnce = (value: TOutputs) => {
                if (!resolved) {
                    resolved = true;
                    resolve(value);
                }
            };

            const rejectOnce = (error: Error) => {
                if (!resolved) {
                    resolved = true;
                    reject(error);
                }
            };

            // Set up listener for task completion/errors
            this.onTaskComplete<TInputs, TOutputs>((taskResult) => {
                // Verify this is the correct task by checking taskId matches
                if (taskResult.taskId !== taskId) {
                    return; // This is a different task, ignore it
                }

                if (taskResult.status === TaskStatus.Failed) {
                    rejectOnce(new Error(taskResult.errorMessage || "Task failed"));
                }
                else {
                    resolveOnce(taskResult.outputs as TOutputs);
                }
            });
        });
    }

    // Waits for all pending tasks to complete
    async awaitAllTasks(): Promise<void> {
        if (this.activeTasksCount === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolvers.push({ resolve, reject });
            this.checkAllTasksComplete();
        });
    }

    // Returns the current queue status (running, completed, failed counts)
    getStatus(): IQueueStatus {
        return {
            pending: 0, // WebSocket tasks are sent immediately, no pending state
            running: this.activeTasksCount,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            peakWorkers: 1 // WebSocket connection is single-threaded
        };
    }

    // Returns worker state information (represents the WebSocket connection as a single worker)
    getWorkerState(): IWorkerInfo[] {
        // Return a single "worker" representing the WebSocket connection
        return [{
            workerId: 1,
            isReady: this.ws.readyState === WebSocket.OPEN,
            isIdle: this.activeTasksCount === 0,
            currentTaskId: null, // We don't track individual task IDs
            currentTaskType: null, // We don't track this for WebSocket tasks
            currentTaskRunningTimeMs: null,
            tasksProcessed: this.tasksCompleted + this.tasksFailed,
        }];
    }

    // Registers a callback for worker state changes
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    // Registers a callback for task messages, filtered by message type
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    // Registers a callback for any task message, regardless of type
    onAnyTaskMessage<TMessage = any>(callback: TaskMessageCallback<TMessage>): void {
        this.anyMessageCallbacks.push(callback as TaskMessageCallback<any>);
    }

    // Notifies all registered completion callbacks with the task result
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

    // Notifies all registered message callbacks that match the message type
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

    //
    // Checks if all tasks are complete and resolves awaitAllTasks() if so
    // Called after each task completes
    //
    private checkAllTasksComplete(): void {
        if (this.activeTasksCount === 0 && this.allTasksResolvers.length > 0) {
            const resolvers = this.allTasksResolvers;
            this.allTasksResolvers = [];
            for (const resolver of resolvers) {
                resolver.resolve();
            }
        }
    }

    //
    // Shuts down the task queue (no-op for WebSocket as connection may be shared)
    //
    shutdown(): void {
        // Don't close the WebSocket connection because we don't own it
    }
}


