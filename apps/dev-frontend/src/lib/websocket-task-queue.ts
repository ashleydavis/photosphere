import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { v4 as uuidv4 } from "uuid";

//
// WebSocket-based task queue implementation
// Communicates with dev-server via WebSocket to queue and execute tasks
//
export class WebSocketTaskQueue implements ITaskQueue {
    private ws: WebSocket;
    private pendingTasks: Map<string, { resolve: (result: ITaskResult) => void; reject: (error: Error) => void }> = new Map();
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType?: string; callback: TaskMessageCallback<any> }> = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private pendingTaskIds: Set<string> = new Set();
    private runningTaskIds: Set<string> = new Set();
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;

    constructor(ws: WebSocket) {
        this.ws = ws;
        this.setupMessageHandler();
    }

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

    private handleMessage(message: any): void {
        if (message.type === "task-result") {
            const { taskId, result } = message;
            const pendingTask = this.pendingTasks.get(taskId);
            
            if (pendingTask) {
                this.pendingTasks.delete(taskId);
                this.runningTaskIds.delete(taskId);
                
                const taskType = result.taskType || "unknown";
                const duration = result.startedAt && result.completedAt 
                    ? result.completedAt.getTime() - result.startedAt.getTime()
                    : 0;
                
                if (result.status === TaskStatus.Completed) {
                    this.tasksCompleted++;
                    console.log(`[TaskQueue] Task completed: ${taskId} (type: ${taskType}, duration: ${duration}ms)`);
                }
                else if (result.status === TaskStatus.Failed) {
                    this.tasksFailed++;
                    const errorMessage = result.errorMessage || "Unknown error";
                    console.log(`[TaskQueue] Task failed: ${taskId} (type: ${taskType}, duration: ${duration}ms, error: ${errorMessage})`);
                }
                
                pendingTask.resolve(result);
                this.notifyCompletionCallbacks(result);
            }
        }
        else if (message.type === "task-message" || message.type === "asset-page") {
            // Handle task messages (including asset-page which is a type of message)
            const { taskId } = message;
            const taskMessage = message.type === "asset-page" ? { type: "asset-page", batch: message.batch } : message.message;
            this.notifyMessageCallbacks(taskId, taskMessage);
        }
    }

    addTask(type: string, data: any): string {
        const taskId = uuidv4();
        this.tasksQueued++;
        this.pendingTaskIds.add(taskId);
        
        const message = {
            type: "queue-task",
            taskId,
            taskType: type,
            data,
        };
        
        this.ws.send(JSON.stringify(message));
        console.log(`[TaskQueue] Task added: ${taskId} (type: ${type})`);
        
        // Move to running when task starts
        this.pendingTaskIds.delete(taskId);
        this.runningTaskIds.add(taskId);
        console.log(`[TaskQueue] Task started: ${taskId} (type: ${type})`);
        
        return taskId;
    }

    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    async awaitAllTasks(): Promise<void> {
        // Wait for all pending and running tasks to complete
        while (this.pendingTaskIds.size > 0 || this.runningTaskIds.size > 0) {
            await new Promise<void>((resolve) => {
                const checkInterval = setInterval(() => {
                    if (this.pendingTaskIds.size === 0 && this.runningTaskIds.size === 0) {
                        clearInterval(checkInterval);
                        resolve();
                    }
                }, 100);
            });
        }
    }

    getStatus(): IQueueStatus {
        return {
            pending: this.pendingTaskIds.size,
            running: this.runningTaskIds.size,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            tasksQueued: this.tasksQueued,
            peakWorkers: 1 // WebSocket connection is single-threaded
        };
    }

    getWorkerState(): IWorkerInfo[] {
        // Return a single "worker" representing the WebSocket connection
        return [{
            workerId: 1,
            isReady: this.ws.readyState === WebSocket.OPEN,
            isIdle: this.runningTaskIds.size === 0,
            currentTaskId: this.runningTaskIds.size > 0 ? Array.from(this.runningTaskIds)[0] : null,
            currentTaskType: null, // We don't track this for WebSocket tasks
            currentTaskRunningTimeMs: null,
            tasksProcessed: this.tasksCompleted + this.tasksFailed,
        }];
    }

    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    shutdown(): void {
        // Close WebSocket connection if we own it
        // Note: We don't close it here because it might be shared
    }

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

    private async notifyMessageCallbacks(taskId: string, message: any): Promise<void> {
        const messageType = message && typeof message === "object" && "type" in message ? message.type : undefined;
        
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            // If a filter type is specified, only invoke if it matches
            if (filterType && messageType !== filterType) {
                continue;
            }
            
            try {
                await callback(taskId, message);
            }
            catch (error: unknown) {
                console.error("Error in task message callback:", error);
            }
        }
    }
}

