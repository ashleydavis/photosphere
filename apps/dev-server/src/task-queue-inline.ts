import type { ITaskQueue, IQueueStatus, IWorkerInfo } from "task-queue";
import { TaskStatus, type ITaskResult, type TaskCompletionCallback, type WorkerStateChangeCallback, type TaskMessageCallback } from "task-queue";
import { executeTaskHandler } from "task-queue/src/lib/worker";
import type { ITaskContext } from "task-queue";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { initTaskHandlers } from "api";
import { RandomUuidGenerator } from "utils";

interface IMessageCallback {
    messageType: string;
    callback: TaskMessageCallback<any>;
}

interface IAnyMessageCallback {
    callback: TaskMessageCallback<any>;
}

interface IBaseTaskContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
}

//
// Task data structure
//
interface ITask {
    id: string;
    type: string;
    status: TaskStatus;
    data: any;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
    timeoutCount: number;
}

//
// Inline task queue that executes tasks directly without workers
// Supports up to maxConcurrent tasks running at once
//
export class TaskQueueInline implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private pendingTasks: string[] = [];
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: IMessageCallback[] = [];
    private anyMessageCallbacks: IAnyMessageCallback[] = [];
    private tasksQueued: number = 0;
    private tasksPending: number = 0;
    private tasksRunning: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private maxConcurrent: number;
    private uuidGenerator: RandomUuidGenerator;
    private timestampProvider: ITimestampProvider;
    private baseContext: IBaseTaskContext;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;
    private allTasksResolvers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

    // Initializes the inline task queue with max concurrent tasks and working directory
    constructor(maxConcurrent: number, uuidGenerator: RandomUuidGenerator, timestampProvider: ITimestampProvider, workerOptions: { verbose: boolean; sessionId: string }) {
        this.maxConcurrent = maxConcurrent;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        
        // Initialize task handlers
        initTaskHandlers();
        
        // Create base worker context (without sendMessage - that will be task-specific)
        // Note: We create our own context here instead of using initWorkerContext
        // because initWorkerContext sets up worker-specific logging which we don't need
        this.baseContext = {
            uuidGenerator: this.uuidGenerator,
            timestampProvider: this.timestampProvider,
            sessionId: workerOptions.sessionId,
        };
    }

    // Adds a task to the queue and returns its ID
    addTask(type: string, data: any, taskId?: string): string {
        const id = taskId || this.uuidGenerator.generate();

        const task: ITask = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            createdAt: this.timestampProvider.dateNow(),
            timeoutCount: 0
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        this.tasksPending++;
        
        this.processNextTask();

        return id;
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

    // Waits for all pending and running tasks to complete
    async awaitAllTasks(): Promise<void> {
        if (this.tasksPending === 0 && this.tasksRunning === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolvers.push({ resolve, reject });
            this.checkAllTasksComplete();
        });
    }

    // Returns the current queue status (pending, running, completed, failed counts)
    getStatus(): IQueueStatus {
        return {
            pending: this.tasksPending,
            running: this.tasksRunning,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
            peakWorkers: this.maxConcurrent
        };
    }

    // Returns fake worker state information for compatibility (inline execution doesn't use real workers)
    getWorkerState(): IWorkerInfo[] {
        // Return fake worker info for compatibility
        return Array.from({ length: this.maxConcurrent }, (_, i) => ({
            workerId: i + 1,
            isReady: true,
            isIdle: this.tasksRunning <= i,
            currentTaskId: null, // We don't track which task is on which "worker"
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
        }));
    }

    // Registers a callback for worker state changes (not used in inline execution)
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    // Registers a callback for task messages, filtered by message type
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void {
        this.messageCallbacks.push({ messageType, callback: callback as TaskMessageCallback<any> });
    }

    // Registers a callback for any task message, regardless of type
    onAnyTaskMessage<TMessage = any>(callback: TaskMessageCallback<TMessage>): void {
        this.anyMessageCallbacks.push({ callback: callback as TaskMessageCallback<any> });
    }

    // Processes the next pending task if capacity is available
    private async processNextTask(): Promise<void> {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        if (this.tasksRunning >= this.maxConcurrent) {
            // The maximum number of concurrent tasks is reached, so we don't process any more tasks yet.
            return;
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        // Mark task as running
        task.status = TaskStatus.Running;
        task.startedAt = this.timestampProvider.dateNow();
        this.tasksPending--;
        this.tasksRunning++;

        // Execute task inline
        this.executeTask(task).catch((error) => {
            console.error(`Error executing task ${taskId}:`, error);
        });

        // Process next task if we still have capacity
        this.processNextTask();
    }

    // Executes a task inline and handles completion or failure
    private async executeTask(task: ITask): Promise<void> {
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
            task.status = TaskStatus.Completed;
            task.completedAt = this.timestampProvider.dateNow();
            const result: ITaskResult = {
                status: TaskStatus.Completed,
                outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };

            this.tasksCompleted++;
            this.tasksRunning--;
            await this.notifyCompletionCallbacks(result);
            this.tasks.delete(task.id);
            this.checkAllTasksComplete();

            // Process next task up to the concurrent limit
            this.processNextTask();
        }
        catch (error: any) {
            // Task failed
            task.status = TaskStatus.Failed;
            task.completedAt = this.timestampProvider.dateNow();
            const err = error instanceof Error ? error : new Error(String(error));
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: err,
                errorMessage: err.message || "Unknown error",
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };

            this.tasksFailed++;
            this.tasksRunning--;
            await this.notifyCompletionCallbacks(result);
            this.tasks.delete(task.id);
            this.checkAllTasksComplete();

            // Process next task
            this.processNextTask();
        }
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
        for (const { callback } of this.anyMessageCallbacks) {
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
        if (this.tasksPending === 0 && this.tasksRunning === 0 && this.allTasksResolvers.length > 0) {
            const resolvers = this.allTasksResolvers;
            this.allTasksResolvers = [];
            for (const resolver of resolvers) {
                resolver.resolve();
            }
        }
    }

    //
    // Shuts down the task queue (no-op for inline execution)
    //
    shutdown(): void {
        // Nothing to shut down for inline execution
    }
}
