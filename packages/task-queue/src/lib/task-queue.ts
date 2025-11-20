import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { IUuidGenerator } from "utils";
import { serializeError } from "serialize-error";
import { registerHandler as registerHandlerInStorage, WorkerMessage, type TaskHandler } from "./task-worker";

//
// Task status enumeration
//
export enum TaskStatus {
    Pending = "pending",
    Running = "running",
    Completed = "completed",
    Failed = "failed"
}

//
// Task result interface
//
export interface ITaskResult {
    status: TaskStatus;
    message?: string;
    error?: string;
    outputs?: any; // The actual result data returned by the handler
    inputs: any; // The original arguments/data sent to the task
    taskId: string;
    taskType: string;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
}

//
// Task data structure
//
interface ITask {
    id: string;
    type: string;
    status: TaskStatus;
    data: any;
    result?: ITaskResult;
    workingDirectory: string;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
    timeoutCount: number; // Track number of times this task has timed out
}

//
// Task handler function type
// Returns the result payload (can be any type)
// Re-exported from worker.ts to avoid duplication
//
export type { TaskHandler };

//
// Task completion callback
//
export type TaskCompletionCallback = (result: ITaskResult) => void;

//
// Queue status interface
//
export interface IQueueStatus {
    pending: number;
    running: number;
    completed: number;
    failed: number;
    total: number;
}

//
// Execution statistics interface
//
export interface IExecutionStats {
    tasksQueued: number;
    maxWorkers: number;
    completed: number;
    failed: number;
}

//
// Task queue interface
//
export interface ITaskQueue {
    //
    // Adds a task to the queue to be run. Returns uuid of the task.
    //
    addTask(type: string, data: any): string;

    //
    // Registers a task handler that can do some work for a named type of task
    // (e.g. "upload-image") then return a result payload.
    //
    registerHandler(type: string, handler: TaskHandler): void;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    //
    onTaskComplete(callback: TaskCompletionCallback): void;

    //
    // Awaits the completion of a particular task.
    //
    awaitTask(id: string): Promise<ITaskResult>;

    //
    // Retrieves the status of a particular task.
    //
    taskStatus(id: string): ITaskResult | undefined;

    //
    // Gets the full result of a particular task (including payload).
    //
    getTaskResult(id: string): ITaskResult | undefined;

    //
    // Gets results for all tasks.
    //
    getAllTaskResults(): ITaskResult[];

    //
    // Gets results for all successful tasks.
    //
    getSuccessfulTaskResults(): ITaskResult[];

    //
    // Gets results for all failed tasks.
    //
    getFailedTaskResults(): ITaskResult[];

    //
    // Awaits the completion of all tasks and an empty queue.
    //
    awaitAllTasks(): Promise<void>;

    //
    // Gets the status of the queue: number of pending tasks, successful tasks, failed tasks, etc.
    //
    getStatus(): IQueueStatus;

    //
    // Gets execution statistics: number of tasks queued, workers used, completed, and failed.
    //
    getExecutionStats(): IExecutionStats;

    //
    // Shuts down the task queue and terminates all workers.
    //
    shutdown(): void;
}

//
// Worker state interface
//
interface IWorkerState {
    worker: Worker;
    workerId: number;
    isIdle: boolean;
    currentTaskId: string | null;
}

//
// Task queue implementation using Bun workers
//
export class TaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private handlers: Map<string, TaskHandler> = new Map();
    private pendingTasks: string[] = [];
    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private baseWorkingDirectory: string;
    private uuidGenerator: IUuidGenerator;
    private taskResolvers: Map<string, { resolve: (result: ITaskResult) => void; reject: (error: Error) => void }> = new Map();
    private allTasksResolver: { resolve: () => void; reject: (error: Error) => void } | null = null;
    private completionCallbacks: TaskCompletionCallback[] = [];
    private tasksQueued: number = 0;
    private workerPath: string;
    private taskTimeout: number;
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // workerPath: Path to the worker script file (must be provided by the caller).
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    //
    constructor(maxWorkers: number = 4, workerPath: string, baseWorkingDirectory?: string, uuidGenerator?: IUuidGenerator, taskTimeout: number = 600000) {
        this.maxWorkers = maxWorkers;
        this.workerPath = workerPath;
        this.baseWorkingDirectory = baseWorkingDirectory || join(tmpdir(), "task-queue");
        this.uuidGenerator = uuidGenerator || {
            generate: () => randomUUID()
        } as IUuidGenerator;
        this.taskTimeout = taskTimeout;

        // Create and start worker pool
        this.startWorkers();
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    // The task will be executed when a worker becomes available.
    //
    addTask(type: string, data: any): string {
        const id = this.uuidGenerator.generate();
        const workingDirectory = join(this.baseWorkingDirectory, id);

        const task: ITask = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            workingDirectory,
            createdAt: new Date(),
            timeoutCount: 0
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        this.processNextTask();

        return id;
    }

    //
    // Registers a handler function for a specific task type.
    // The handler will be called to process tasks of this type.
    //
    registerHandler(type: string, handler: TaskHandler): void {
        this.handlers.set(type, handler);
        registerHandlerInStorage(type, handler);
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: TaskCompletionCallback): void {
        this.completionCallbacks.push(callback);
    }

    //
    // Waits for a specific task to complete and returns its result.
    // If the task is already complete, returns immediately.
    // Throws an error if the task ID is not found.
    //
    async awaitTask(id: string): Promise<ITaskResult> {
        const task = this.tasks.get(id);
        if (!task) {
            throw new Error(`Task ${id} not found`);
        }

        if (task.status === TaskStatus.Completed || task.status === TaskStatus.Failed) {
            return {
                status: task.status,
                message: task.result?.message,
                error: task.result?.error,
                outputs: task.result?.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
        }

        return new Promise<ITaskResult>((resolve, reject) => {
            this.taskResolvers.set(id, { resolve, reject });
        });
    }

    //
    // Gets the current status and result of a task without waiting.
    // Returns undefined if the task ID is not found.
    //
    taskStatus(id: string): ITaskResult | undefined {
        const task = this.tasks.get(id);
        if (!task) {
            return undefined;
        }

        return {
            status: task.status,
            message: task.result?.message,
            error: task.result?.error,
            outputs: task.result?.outputs,
            inputs: task.data,
            taskId: task.id,
            taskType: task.type,
            createdAt: task.createdAt,
            startedAt: task.startedAt,
            completedAt: task.completedAt
        };
    }

    //
    // Gets the full result of a specific task (same as taskStatus but more explicit).
    // Returns undefined if the task ID is not found.
    //
    getTaskResult(id: string): ITaskResult | undefined {
        return this.taskStatus(id);
    }

    //
    // Returns results for all tasks (pending, running, completed, and failed).
    // Useful for getting a complete snapshot of all tasks in the queue.
    //
    getAllTaskResults(): ITaskResult[] {
        const results: ITaskResult[] = [];
        for (const task of this.tasks.values()) {
            results.push({
                status: task.status,
                message: task.result?.message,
                error: task.result?.error,
                outputs: task.result?.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            });
        }
        return results;
    }

    //
    // Returns results for all successfully completed tasks.
    // Useful for processing only successful results.
    //
    getSuccessfulTaskResults(): ITaskResult[] {
        return this.getAllTaskResults().filter(result => result.status === TaskStatus.Completed);
    }

    //
    // Returns results for all failed tasks.
    // Useful for error handling and retry logic.
    //
    getFailedTaskResults(): ITaskResult[] {
        return this.getAllTaskResults().filter(result => result.status === TaskStatus.Failed);
    }

    //
    // Waits for all pending and running tasks to complete.
    // Resolves when the queue is empty (no pending or running tasks).
    //
    async awaitAllTasks(): Promise<void> {
        const runningCount = this.workers.filter(w => !w.isIdle).length;
        if (this.pendingTasks.length === 0 && runningCount === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolver = { resolve, reject };
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of pending, running, completed, and failed tasks.
    // Useful for monitoring and progress tracking.
    //
    getStatus(): IQueueStatus {
        let pending = 0;
        let running = 0;
        let completed = 0;
        let failed = 0;

        for (const task of this.tasks.values()) {
            switch (task.status) {
                case TaskStatus.Pending:
                    pending++;
                    break;
                case TaskStatus.Running:
                    running++;
                    break;
                case TaskStatus.Completed:
                    completed++;
                    break;
                case TaskStatus.Failed:
                    failed++;
                    break;
            }
        }

        return {
            pending,
            running,
            completed,
            failed,
            total: this.tasks.size
        };
    }

    //
    // Gets execution statistics: number of tasks queued, workers used, completed, and failed.
    // Useful for debug logging and performance analysis.
    //
    getExecutionStats(): IExecutionStats {
        const status = this.getStatus();
        return {
            tasksQueued: this.tasksQueued,
            maxWorkers: this.maxWorkers,
            completed: status.completed,
            failed: status.failed
        };
    }

    //
    // Internal: Creates and starts all workers in the pool.
    //
    private startWorkers(): void {
        for (let i = 0; i < this.maxWorkers; i++) {
            const worker = new Worker(this.workerPath);
            const workerState: IWorkerState = {
                worker,
                workerId: i + 1,
                isIdle: false, // Start as not ready, will be set to true when worker sends "ready" message
                currentTaskId: null
            };

            worker.addEventListener("message", (event: MessageEvent) => {
                this.handleWorkerMessage(workerState, event.data);
            });

            worker.addEventListener("error", (error) => {
                console.error(`[Worker ${workerState.workerId}] Error: ${error.message || "Unknown error"}`);
                this.handleWorkerCrash(workerState);
            });

            worker.addEventListener("messageerror", (error) => {
                console.error(`[Worker ${workerState.workerId}] Message error:`, error);
                this.handleWorkerCrash(workerState);
            });

            this.workers.push(workerState);
        }
    }

    //
    // Internal: Processes the next pending task if a worker is available.
    // Called automatically when tasks are added or completed.
    //
    private processNextTask(): void {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        // Find an available idle worker
        const availableWorker = this.workers.find(w => w.isIdle);
        if (!availableWorker) {
            return; // All workers busy
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        // Note: Handler registration is checked in the worker thread, not here.
        // The worker will report if a handler is missing when it tries to execute the task.

        // Mark task as running and assign to worker
        task.status = TaskStatus.Running;
        task.startedAt = new Date();
        availableWorker.isIdle = false;
        availableWorker.currentTaskId = taskId;

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(taskId, availableWorker);
        }, this.taskTimeout);
        this.taskTimeouts.set(taskId, timeoutId);

        // Send task to worker
        try {
            const executeMsg: WorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
                workingDirectory: task.workingDirectory,
            };
            availableWorker.worker.postMessage(executeMsg);
        } catch (error) {
            console.error(`Error sending task to worker ${availableWorker.workerId}:`, error);
            // Clear timeout on error
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }
            this.handleWorkerCrash(availableWorker);
        }
    }


    //
    // Internal: Handles messages from worker threads.
    // Processes task results and errors.
    //
    private handleWorkerMessage(workerState: IWorkerState, data: any): void {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "ready") {
            workerState.isIdle = true;
            this.processNextTask(); // Try to process pending tasks now that worker is ready
            return;
        }

        // Handle task result
        if (data && typeof data === "object" && "type" in data && data.type === "result") {
            const { taskId, result } = data;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            // Clear timeout since task completed successfully
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            task.status = TaskStatus.Completed;
            task.completedAt = new Date();
            const fullResult: ITaskResult = {
                status: TaskStatus.Completed,
                message: result.message,
                outputs: result.outputs,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = fullResult;

            workerState.isIdle = true;
            workerState.currentTaskId = null;

            this.notifyCompletionCallbacks(fullResult);
            this.resolveTask(taskId, fullResult);
            this.processNextTask();
            return;
        }

        // Handle task error
        if (data && typeof data === "object" && "type" in data && data.type === "error") {
            const { taskId, error } = data;
            const task = this.tasks.get(taskId);
            if (!task) {
                return;
            }

            // Clear timeout since task completed (with error)
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const errorString = error ? JSON.stringify(serializeError(error)) : "Unknown error";
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: errorString,
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            workerState.isIdle = true;
            workerState.currentTaskId = null;

            this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            this.processNextTask();
            return;
        }
    }

    //
    // Internal: Handles task timeout by terminating the worker, requeuing the task, and replacing the worker.
    // Only allows up to 3 timeouts per task, after which the task is marked as failed.
    //
    private handleTaskTimeout(taskId: string, workerState: IWorkerState): void {
        const task = this.tasks.get(taskId);
        if (!task || task.status !== TaskStatus.Running) {
            // Task already completed or doesn't exist, ignore timeout
            return;
        }

        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        // Increment timeout count
        task.timeoutCount++;

        console.error(`[Task Queue] Task ${taskId} timed out after ${this.taskTimeout}ms (timeout count: ${task.timeoutCount}/3)`);

        // Terminate the worker
        try {
            workerState.worker.terminate();
        } catch (error) {
            console.error(`[Task Queue] Error terminating worker ${workerState.workerId}:`, error);
        }

        // Check if we've exceeded the maximum number of timeouts
        if (task.timeoutCount >= 3) {
            // Mark task as failed after 3 timeouts
            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const error = new Error(`Task timed out ${task.timeoutCount} times (exceeded maximum of 3)`);
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: JSON.stringify(serializeError(error)),
                inputs: task.data,
                taskId: task.id,
                taskType: task.type,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                completedAt: task.completedAt
            };
            task.result = result;

            workerState.isIdle = true;
            workerState.currentTaskId = null;

            this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            this.processNextTask();

            // Replace the worker
            this.replaceWorker(workerState);
        } else {
            // Requeue the task for retry
            task.status = TaskStatus.Pending;
            task.startedAt = undefined;
            this.pendingTasks.unshift(taskId); // Add to front of queue for priority

            // Replace the worker
            this.replaceWorker(workerState);
        }
    }

    //
    // Internal: Handles worker crashes by terminating the worker and creating a replacement.
    // If the worker had a task, it will be requeued.
    //
    private handleWorkerCrash(workerState: IWorkerState): void {
        const crashedTaskId = workerState.currentTaskId;

        // Terminate the crashed worker
        try {
            workerState.worker.terminate();
        } catch (e) {
            // Worker may already be terminated
        }

        // If worker had a task, clear its timeout and requeue it
        if (crashedTaskId) {
            const timeout = this.taskTimeouts.get(crashedTaskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(crashedTaskId);
            }

            const task = this.tasks.get(crashedTaskId);
            if (task && task.status === TaskStatus.Running) {
                task.status = TaskStatus.Pending;
                task.startedAt = undefined;
                this.pendingTasks.unshift(crashedTaskId); // Add to front of queue for priority
            }
        }

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Internal: Replaces a worker with a new one.
    //
    private replaceWorker(oldWorkerState: IWorkerState): void {
        // Remove from workers array
        const index = this.workers.indexOf(oldWorkerState);
        if (index > -1) {
            this.workers.splice(index, 1);
        }

        // Create replacement worker
        const worker = new Worker(this.workerPath);
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isIdle: false,
            currentTaskId: null
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(newWorkerState, event.data);
        });

        worker.addEventListener("error", (error) => {
            console.error(`[Worker ${newWorkerState.workerId}] Error: ${error.message || "Unknown error"}`);
            this.handleWorkerCrash(newWorkerState);
        });

        worker.addEventListener("messageerror", (error) => {
            console.error(`[Worker ${newWorkerState.workerId}] Message error:`, error);
            this.handleWorkerCrash(newWorkerState);
        });

        this.workers.push(newWorkerState);
    }

    //
    // Internal: Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    //
    private notifyCompletionCallbacks(result: ITaskResult): void {
        for (const callback of this.completionCallbacks) {
            try {
                callback(result);
            } catch (error) {
                // Don't let callback errors break the task queue
                console.error("Error in task completion callback:", error);
            }
        }
    }


    //
    // Internal: Resolves any promises waiting for this task to complete.
    // Also checks if all tasks are complete to resolve awaitAllTasks().
    //
    private resolveTask(taskId: string, result: ITaskResult): void {
        const resolver = this.taskResolvers.get(taskId);
        if (resolver) {
            this.taskResolvers.delete(taskId);
            resolver.resolve(result);
        }

        this.checkAllTasksComplete();
    }

    //
    // Internal: Checks if all tasks are complete and resolves awaitAllTasks() if so.
    // Called after each task completes.
    //
    private checkAllTasksComplete(): void {
        const runningCount = this.workers.filter(w => !w.isIdle).length;
        if (this.allTasksResolver && this.pendingTasks.length === 0 && runningCount === 0) {
            const resolver = this.allTasksResolver;
            this.allTasksResolver = null;
            resolver.resolve();
        }
    }

    //
    // Shuts down the task queue and cleans up resources.
    // Terminates all workers and should be called when the queue is no longer needed.
    //
    shutdown(): void {
        // Clear all timeouts
        for (const timeout of this.taskTimeouts.values()) {
            clearTimeout(timeout);
        }
        this.taskTimeouts.clear();

        for (const workerState of this.workers) {
            try {
                workerState.worker.terminate();
            } catch (e) {
                // Ignore termination errors
            }
        }
        this.workers = [];
    }
}

