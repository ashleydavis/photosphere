import { join } from "node:path";
import { IUuidGenerator, log } from "utils";
import { deserializeError } from "serialize-error";
import type { TaskHandler, WorkerMessage, IWorkerOptions } from "./types";

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
export interface ITaskResult<TInputs = any, TOutputs = any> {
    status: TaskStatus;
    message?: string;
    error?: Error; // Deserialized error object (automatically deserialized from JSON)
    errorMessage?: string; // Convenience field: error?.message || "Unknown error"
    outputs?: TOutputs; // The actual result data returned by the handler
    inputs: TInputs; // The original arguments/data sent to the task
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
// Can be synchronous or asynchronous
//
export type TaskCompletionCallback<TInputs = any, TOutputs = any> = (result: ITaskResult<TInputs, TOutputs>) => void | Promise<void>;

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
    peakWorkers: number;
    completed: number;
    failed: number;
}

//
// Worker state information for debugging
//
export interface IWorkerInfo {
    workerId: number;
    isReady: boolean;
    isIdle: boolean;
    currentTaskId: string | null;
    currentTaskType: string | null;
    currentTaskRunningTimeMs: number | null; // Time in milliseconds the current task has been running, or null if no task is running
    tasksProcessed: number; // Number of tasks this worker has completed (successful or failed)
}

//
// Callback for worker state changes
//
export type WorkerStateChangeCallback = (workers: IWorkerInfo[]) => void;

//
// Task queue interface
//
export interface ITaskQueue {
    //
    // Adds a task to the queue to be run. Returns uuid of the task.
    //
    addTask(type: string, data: any): string;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void;

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
    // Gets current state of all workers for debugging.
    //
    getWorkerState(): IWorkerInfo[];

    //
    // Sets a callback to be notified when worker state changes.
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void;

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
    isReady: boolean; // Worker has sent "ready" message and can process tasks
    isIdle: boolean; // Worker is ready and not currently processing a task
    currentTaskId: string | null;
    tasksProcessed: number; // Number of tasks this worker has completed (successful or failed)
}

//
// Task queue implementation using Bun workers
//
export class TaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask> = new Map();
    private pendingTasks: string[] = [];
    private workers: IWorkerState[] = [];
    private maxWorkers: number;
    private peakWorkers: number = 0;
    private baseWorkingDirectory: string;
    private uuidGenerator: IUuidGenerator;
    private allTasksResolver: { resolve: () => void; reject: (error: Error) => void } | null = null;
    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private tasksQueued: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private workerPath: string;
    private taskTimeout: number;
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();
    private workerOptions?: IWorkerOptions;
    private workerStateChangeCallback: WorkerStateChangeCallback | null = null;

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // workerPath: Path to the worker script file (must be provided by the caller).
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    // workerOptions: Options to pass to workers for logging and context initialization.
    //
    constructor(maxWorkers: number, workerPath: string, baseWorkingDirectory: string, uuidGenerator: IUuidGenerator, taskTimeout: number, workerOptions: IWorkerOptions | undefined) {
        this.maxWorkers = maxWorkers;
        this.workerPath = workerPath;
        this.baseWorkingDirectory = baseWorkingDirectory;
        this.uuidGenerator = uuidGenerator;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;

        // Workers will be created lazily when tasks are added
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
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete<TInputs = any, TOutputs = any>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
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

        for (const task of this.tasks.values()) {
            switch (task.status) {
                case TaskStatus.Pending:
                    pending++;
                    break;
                case TaskStatus.Running:
                    running++;
                    break;
            }
        }

        return {
            pending,
            running,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasks.size + this.tasksCompleted + this.tasksFailed
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
            peakWorkers: this.peakWorkers,
            completed: status.completed,
            failed: status.failed
        };
    }

    //
    // Gets current state of all workers for debugging.
    //
    getWorkerState(): IWorkerInfo[] {
        return this.workers.map(worker => {
            let currentTaskRunningTimeMs: number | null = null;
            if (worker.currentTaskId) {
                const task = this.tasks.get(worker.currentTaskId);
                if (task && task.startedAt) {
                    currentTaskRunningTimeMs = Date.now() - task.startedAt.getTime();
                }
            }
            
            return {
                workerId: worker.workerId,
                isReady: worker.isReady,
                isIdle: worker.isIdle,
                currentTaskId: worker.currentTaskId,
                currentTaskType: worker.currentTaskId ? this.tasks.get(worker.currentTaskId)?.type || null : null,
                currentTaskRunningTimeMs,
                tasksProcessed: worker.tasksProcessed
            };
        });
    }

    //
    // Sets a callback to be notified when worker state changes.
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void {
        this.workerStateChangeCallback = callback;
    }

    //
    // Internal: Notifies callback of worker state changes.
    //
    private notifyWorkerStateChange(): void {
        if (this.workerStateChangeCallback) {
            this.workerStateChangeCallback(this.getWorkerState());
        }
    }

    //
    // Internal: Creates a single worker and adds it to the pool.
    // Returns the worker state.
    //
    private createWorker(): IWorkerState {
        // Pass worker options via environment variable
        // Also pass through environment variables needed for tmpdir() to work correctly
        const workerEnv: Record<string, string> = {};
        
        // Pass through temp directory environment variables (needed for os.tmpdir() to work)
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }
        
        if (this.workerOptions) {
            workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        } else {
            workerEnv.WORKER_OPTIONS = JSON.stringify({});
        }
        
        const worker = new Worker(this.workerPath, { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId: this.workers.length + 1,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false, // Will be set to true when worker is ready and idle
            currentTaskId: null,
            tasksProcessed: 0
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(workerState, event.data).catch((error: any) => {
                log.exception("Error handling worker message", error);
            });
        });

        worker.addEventListener("error", (error: any) => {
            log.exception(`Error from worker ${workerState.workerId}`, error);
            this.handleWorkerCrash(workerState);
        });

        worker.addEventListener("messageerror", (error: any) => {
            log.exception(`Error from worker ${workerState.workerId}`, error);
            this.handleWorkerCrash(workerState);
        });

        this.workers.push(workerState);

        // Update peak workers count
        if (this.workers.length > this.peakWorkers) {
            this.peakWorkers = this.workers.length;
        }
        this.notifyWorkerStateChange();
        return workerState;
    }

    //
    // Internal: Processes the next pending task if a worker is available.
    // Called automatically when tasks are added or completed.
    // Creates workers lazily if needed (up to maxWorkers limit).
    //
    private processNextTask(): void {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        // Find an available idle worker that has processed the least tasks
        const idleWorkers = this.workers.filter(w => w.isIdle);
        let availableWorker = idleWorkers.length > 0
            ? idleWorkers.reduce((least, current) => 
                current.tasksProcessed < least.tasksProcessed ? current : least
            )
            : undefined;
        
        // If no idle worker available and we haven't reached maxWorkers, create workers for pending tasks
        if (!availableWorker && this.workers.length < this.maxWorkers) {
            // Count workers that are not ready yet (will become available soon)
            // These workers will be able to process tasks once they're ready, so we should account for them
            let workersNotReadyYet = 0;
            for (const worker of this.workers) {
                if (!worker.isReady) {
                    workersNotReadyYet++;
                }
            }
            
            // Calculate how many workers we need: pending tasks minus workers that will become available
            const workersNeeded = this.pendingTasks.length - workersNotReadyYet; 
            if (workersNeeded > 0) {
                // Create workers for the tasks that need them, up to maxWorkers limit
                const workersToCreate = Math.min(
                    workersNeeded,
                    this.maxWorkers - this.workers.length
                );
                
                for (let i = 0; i < workersToCreate; i++) {
                    this.createWorker();
                }
            }
            
            // Workers won't be idle until they send "ready" messages, so return for now
            return;
        }
        
        if (!availableWorker) {
            return; // All workers busy or not ready yet
        }

        const taskId = this.pendingTasks.shift()!;
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        // Mark task as running and assign to worker
        task.status = TaskStatus.Running;
        task.startedAt = new Date();
        availableWorker.isIdle = false;
        availableWorker.currentTaskId = taskId;
        this.notifyWorkerStateChange();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(taskId, availableWorker!).catch((error: any) => {
                log.exception("Error handling task timeout", error);
            });
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
        } 
        catch (error: any) {
            log.exception(`Error sending task to worker ${availableWorker.workerId}`, error);
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
    private async handleWorkerMessage(workerState: IWorkerState, data: any): Promise<void> {
        // Handle worker ready message
        if (data && typeof data === "object" && "type" in data && data.type === "ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.notifyWorkerStateChange();
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
            workerState.tasksProcessed++;

            this.tasksCompleted++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(fullResult);
            this.resolveTask(taskId, fullResult);
            
            // Remove completed task from memory after reporting result
            this.tasks.delete(taskId);
            
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
            let deserializedError: Error | undefined;
            if (error) {
                try {
                    deserializedError = deserializeError(error);
                } 
                catch {
                    // If deserialization fails, create a generic error
                    deserializedError = new Error(typeof error === 'string' ? error : JSON.stringify(error));
                }
            } else {
                deserializedError = new Error("Unknown error");
            }
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: deserializedError,
                errorMessage: deserializedError.message || "Unknown error",
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
            workerState.tasksProcessed++;

            this.tasksFailed++;

            this.notifyWorkerStateChange();
            await this.notifyCompletionCallbacks(result);
            this.resolveTask(taskId, result);
            
            // Remove failed task from memory after reporting result
            this.tasks.delete(taskId);
            
            this.processNextTask();
            return;
        }
    }

    //
    // Internal: Handles task timeout by terminating the worker, requeuing the task, and replacing the worker.
    // Only allows up to 3 timeouts per task, after which the task is marked as failed.
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
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

        log.error(`[Task Queue] Task ${this.formatTaskId(taskId)} timed out after ${this.taskTimeout}ms (timeout count: ${task.timeoutCount}/3)`);

        // Terminate the worker
        try {
            workerState.worker.terminate();
        } 
        catch (error: any) {
            log.exception(`[Task Queue] Error terminating worker ${workerState.workerId}`, error);
        }

        // Check if we've exceeded the maximum number of timeouts
        if (task.timeoutCount >= 3) {
            // Mark task as failed after 3 timeouts
            task.status = TaskStatus.Failed;
            task.completedAt = new Date();
            const error = new Error(`Task timed out ${task.timeoutCount} times (exceeded maximum of 3)`);
            const result: ITaskResult = {
                status: TaskStatus.Failed,
                error: error,
                errorMessage: error.message,
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

            await this.notifyCompletionCallbacks(result);
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
            this.notifyWorkerStateChange();
        }

        // Create replacement worker
        // Pass worker options via environment variable
        // Also pass through environment variables needed for tmpdir() to work correctly
        const workerEnv: Record<string, string> = {};
        
        // Pass through temp directory environment variables (needed for os.tmpdir() to work)
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }
        
        if (this.workerOptions) {
            workerEnv.WORKER_OPTIONS = JSON.stringify(this.workerOptions);
        } else {
            workerEnv.WORKER_OPTIONS = JSON.stringify({});
        }
        
        const worker = new Worker(this.workerPath, { env: workerEnv });
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false,
            currentTaskId: null,
            tasksProcessed: oldWorkerState.tasksProcessed // Preserve task count when replacing worker
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(newWorkerState, event.data).catch((error: any) => {
                log.exception("Error handling worker message", error);
            });
        });

        worker.addEventListener("error", (error: any) => {
            log.exception(`Error from worker ${newWorkerState.workerId}`, error);
            this.handleWorkerCrash(newWorkerState);
        });

        worker.addEventListener("messageerror", (error: any) => {
            log.exception(`Error from worker ${newWorkerState.workerId}]`, error);
            this.handleWorkerCrash(newWorkerState);
        });

        this.workers.push(newWorkerState);
        this.notifyWorkerStateChange();
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
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", error);
            }
        }
    }


    //
    // Internal: Checks if all tasks are complete to resolve awaitAllTasks().
    //
    private resolveTask(taskId: string, result: ITaskResult): void {
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
    // Formats a task ID to show only first 2 and last 2 characters.
    // Example: "12345678-1234-1234-1234-123456789abc" -> "12bc"
    //
    private formatTaskId(taskId: string): string {
        if (taskId.length <= 4) {
            return taskId;
        }
        return `${taskId.substring(0, 2)}${taskId.substring(taskId.length - 2)}`;
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

