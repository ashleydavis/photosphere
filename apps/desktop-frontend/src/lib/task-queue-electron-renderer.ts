import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { v4 as uuidv4 } from "uuid";
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
// Electron IPC-based task queue implementation
// Communicates with Electron main process via IPC to queue and execute tasks
//
export class TaskQueueElectronRenderer implements ITaskQueue {
    private electronAPI: IElectronAPI;
    private activeTasksCount: number = 0;
    private allTasksResolvers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback<any> }> = [];
    private anyMessageCallbacks: TaskMessageCallback<any>[] = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;

    //
    // Creates a new Electron renderer task queue that communicates with the main process via IPC.
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
    // Adds a task to the queue to be executed in the main process. Returns the task ID (UUID).
    // The task will be executed asynchronously via IPC.
    //
    addTask(type: string, data: any, taskId?: string): string {
        const finalTaskId = taskId || uuidv4();
        this.tasksQueued++;
        this.activeTasksCount++;
        
        this.electronAPI.addTask(type, data, finalTaskId);
        
        return finalTaskId;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    //
    // Adds a task and waits for it to complete, returning the outputs.
    // Throws an error if the task fails.
    //
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
    
    //
    // Waits for all active tasks to complete.
    // Resolves when the queue is empty (no active tasks).
    //
    async awaitAllTasks(): Promise<void> {
        if (this.activeTasksCount === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolvers.push({ resolve, reject });
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of running, completed, and failed tasks.
    // Includes execution statistics: tasks queued, completed, and failed.
    //
    getStatus(): IQueueStatus {
        return {
            pending: 0,
            running: this.activeTasksCount,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            peakWorkers: 1 // Electron IPC is single-threaded from renderer perspective
        };
    }

    //
    // Gets current state of workers for debugging.
    // Returns a single worker info object representing the IPC connection.
    //
    getWorkerState(): IWorkerInfo[] {
        return [{
            workerId: 1,
            isReady: true,
            isIdle: this.activeTasksCount === 0,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: this.tasksCompleted + this.tasksFailed,
        }];
    }

    //
    // Sets a callback to be notified when worker state changes.
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    //
    // Registers a callback that will be called for all task messages, regardless of type.
    //
    onAnyTaskMessage<TMessage = any>(callback: TaskMessageCallback<TMessage>): void {
        this.anyMessageCallbacks.push(callback as TaskMessageCallback<any>);
    }

    //
    // Internal: Handles task completion messages from the main process.
    // Updates statistics, resolves pending promises, and notifies callbacks.
    //
    private handleTaskCompleted(data: ITaskCompletionResponse): void {
        const { taskId, result } = data;

        if (this.activeTasksCount === 0) {
            throw new Error("Task completed but no active tasks");
        }
        
        this.activeTasksCount--;
        
        if (!result.taskType) {
            throw new Error(`Task result missing taskType for task ${taskId}`);
        }
        
        if (result.status === TaskStatus.Completed) {
            this.tasksCompleted++;
        }
        else if (result.status === TaskStatus.Failed) {
            this.tasksFailed++;
        }
        
        this.notifyCompletionCallbacks(result);
        this.checkAllTasksComplete();
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
        const messageType = message.type;
        
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
    // Internal: Checks if all tasks are complete and resolves awaitAllTasks() if so.
    // Called after each task completes.
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
    // Shuts down the task queue and cleans up resources.
    // Removes all IPC message listeners and should be called when the queue is no longer needed.
    //
    shutdown(): void {
        // Cleanup message listeners
        this.electronAPI.removeAllListeners('task-completed');
        this.electronAPI.removeAllListeners('task-message');
    }
}

