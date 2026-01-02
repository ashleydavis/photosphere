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
export class WebSocketTaskQueue implements ITaskQueue {
    private ws: WebSocket;
    private pendingTasks: Map<string, { resolve: (result: ITaskResult) => void; reject: (error: Error) => void }> = new Map();
    private activeTasksCount: number = 0;
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback<any> }> = [];
    private anyMessageCallbacks: TaskMessageCallback<any>[] = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;

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
                console.log(`[TaskQueue] Received message:`);
                console.log(JSON.stringify(message, null, 2));
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
            
            const pendingTask = this.pendingTasks.get(taskId);
            if (pendingTask) {
                this.pendingTasks.delete(taskId);
                
                if (result.status === TaskStatus.Failed) {
                    pendingTask.reject(new Error(result.errorMessage || "Task failed"));
                }
                else {
                    pendingTask.resolve(result);
                }
            }
            
            this.notifyCompletionCallbacks(result);
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
        
        const message = {
            type: "queue-task",
            taskId: finalTaskId,
            taskType: type,
            data,
        };
        
        this.ws.send(JSON.stringify(message));
        
        console.log(`[TaskQueue] Task added: ${finalTaskId} (type: ${type})`);
        
        return finalTaskId;
    }

    // Registers a callback to be invoked when any task completes
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    // Adds a task and waits for its completion, returning the result
    async awaitTask<TInputs = any, TOutputs = any>(type: string, data: TInputs): Promise<TOutputs> {

        const taskId = this.addTask(type, data);

        console.log(`[TaskQueue] Awaiting task: ${taskId} (type: ${type})`);

        return new Promise<TOutputs>((resolve, reject) => {
            const pendingTask = this.pendingTasks.get(taskId);
            if (pendingTask) {
                // Task already exists, this shouldn't happen but handle it
                reject(new Error("Task ID collision"));
                return;
            }

            this.pendingTasks.set(taskId, {
                resolve: (result: ITaskResult) => {
                    resolve(result.outputs as TOutputs);
                },
                reject
            });
        });
    }

    // Waits for all pending tasks to complete
    async awaitAllTasks(): Promise<void> {
        // Wait for all tasks to complete
        while (this.activeTasksCount > 0) {
            await new Promise<void>((resolve) => {
                const checkInterval = setInterval(() => {
                    if (this.activeTasksCount === 0) {
                        clearInterval(checkInterval);
                        resolve();
                    }
                }, 100);
            });
        }
    }

    // Returns the current queue status (running, completed, failed counts)
    getStatus(): IQueueStatus {
        const running = this.pendingTasks.size;
        return {
            pending: 0, // WebSocket tasks are sent immediately, no pending state
            running: running,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            tasksQueued: this.tasksQueued,
            peakWorkers: 1 // WebSocket connection is single-threaded
        };
    }

    // Returns worker state information (represents the WebSocket connection as a single worker)
    getWorkerState(): IWorkerInfo[] {
        // Return a single "worker" representing the WebSocket connection
        const runningTaskIds = Array.from(this.pendingTasks.keys());
        return [{
            workerId: 1,
            isReady: this.ws.readyState === WebSocket.OPEN,
            isIdle: this.pendingTasks.size === 0,
            currentTaskId: runningTaskIds.length > 0 ? runningTaskIds[0] : null,
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

    // Shuts down the task queue (no-op for WebSocket as connection may be shared)
    shutdown(): void {
        // Don't close the WebSocket connection because we don't own it
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
}

