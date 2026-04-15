import type { ITask, ITaskResult, WorkerTaskCompletionCallback, TaskMessageCallback, UnsubscribeFn, IMessageCallbackEntry, IQueueBackend } from "task-queue";
import { TaskStatus } from "task-queue";
import { randomUUID } from "node:crypto";
import { utilityProcess, type UtilityProcess } from 'electron';
import { deserializeError } from "serialize-error";

//
// Options passed to each worker process via WORKER_OPTIONS environment variable
//
export interface IWorkerOptions {
    //
    // Numeric identifier assigned to this worker, used in log messages.
    //
    workerId: number;

    //
    // When true, verbose log output is enabled in the worker process.
    //
    verbose: boolean;

    //
    // When true, tool-use logging is enabled in the worker process.
    //
    tools: boolean;

    //
    // Session identifier forwarded to task handlers.
    //
    sessionId: string;
}

//
// Options for configuring a worker pool (does not include workerId, which is assigned per worker)
//
export interface IWorkerPoolOptions {
    //
    // When true, verbose log output is enabled in worker processes.
    //
    verbose: boolean;

    //
    // When true, tool-use logging is enabled in worker processes.
    //
    tools: boolean;

    //
    // Session identifier forwarded to task handlers via IWorkerOptions.
    //
    sessionId: string;
}

//
// Worker message interface for communication between main thread and workers
//
export interface IWorkerMessage {
    //
    // Message type discriminator — always "execute".
    //
    type: "execute";

    //
    // Unique identifier for the task being executed.
    //
    taskId: string;

    //
    // Registered handler name to invoke in the worker.
    //
    taskType: string;

    //
    // Input data passed to the task handler.
    //
    data: unknown;

    //
    // Source tag of the task, used to match cancellation signals.
    //
    source: string;
}

//
// Message sent from main thread to worker to cancel tasks with a given source.
//
export interface IWorkerCancelTasksMessage {
    type: "cancel-tasks";
    source: string;
}

//
// Worker response message types
//
export interface IWorkerReadyMessage {
    //
    // Message type discriminator — sent once when the worker process is initialised.
    //
    type: "worker-ready";
}

export interface IWorkerTaskCompletedMessage {
    //
    // Message type discriminator.
    //
    type: "task-completed";

    //
    // ID of the task that completed.
    //
    taskId: string;

    //
    // Full result payload including status and outputs or error.
    //
    result: ITaskResult;
}

export interface IWorkerTaskMessage {
    //
    // Message type discriminator.
    //
    type: "task-message";

    //
    // ID of the task that sent the message.
    //
    taskId: string;

    //
    // Arbitrary message payload from the task handler.
    //
    message: unknown;
}

//
// Message sent from worker to main thread to request queuing a new task.
//
export interface IWorkerQueueTaskMessage {
    //
    // Message type discriminator.
    //
    type: "queue-task";

    //
    // Pre-assigned task ID from the worker-side TaskQueue so the main thread uses the same ID.
    //
    taskId: string;

    //
    // Registered handler name to invoke.
    //
    taskType: string;

    //
    // Input data for the new task.
    //
    data: any;

    //
    // Source tag to associate the new task with a logical group (e.g. database path).
    //
    source: string;
}

//
// Message sent from a utility process worker to request showing a toast notification in the renderer.
//
export interface IWorkerShowNotificationMessage {
    //
    // Message type discriminator.
    //
    type: "show-notification";

    //
    // The message to display in the toast.
    //
    message: string;

    //
    // Color variant of the toast.
    //
    color: 'success' | 'warning' | 'danger' | 'neutral';

    //
    // Duration in milliseconds before auto-dismiss. 0 means no auto-dismiss.
    //
    duration?: number;
}

//
// Worker state interface
//
interface IWorkerState {
    //
    // The Electron utility process handle.
    //
    worker: UtilityProcess;

    //
    // Numeric identifier for this worker, used in log messages.
    //
    workerId: number;

    //
    // True once the worker has sent its "worker-ready" message.
    //
    isReady: boolean;

    //
    // True when the worker is not currently executing a task.
    //
    isIdle: boolean;

    //
    // ID of the task currently being executed, or null when idle.
    //
    currentTaskId: string | null;

    //
    // Type name of the task currently being executed, or null when idle.
    //
    currentTaskType: string | null;

    //
    // Elapsed milliseconds for the current task, or null when idle.
    //
    currentTaskRunningTimeMs: number | null;

    //
    // Total number of tasks this worker has completed (used for load balancing).
    //
    tasksProcessed: number;

    //
    // Timestamp (Date.now()) when the current task started, or null when idle.
    //
    taskStartTime: number | null;
}

//
// Electron main process implementation of IWorkerPool and IQueueBackend
// Uses utility processes to execute tasks in parallel
//
export class WorkerPoolElectronMain implements IQueueBackend {
    //
    // Active worker process states, one entry per spawned utility process.
    //
    private workers: IWorkerState[] = [];

    //
    // Maximum number of concurrent utility process workers.
    //
    private maxWorkers: number;

    //
    // Absolute path to the worker entry-point script passed to utilityProcess.fork.
    //
    private workerPath: string;

    //
    // Options forwarded to each worker via the WORKER_OPTIONS environment variable.
    //
    private backendOptions: IWorkerPoolOptions;

    //
    // Maximum time in milliseconds a task may run before being forcibly killed.
    //
    private taskTimeout: number;

    //
    // Per-task timeout handles, cleared when the task completes normally.
    //
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();

    //
    // Callbacks invoked whenever any task completes (success or failure).
    //
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    //
    // Callbacks invoked when a task emits a message of a specific type.
    //
    private messageCallbacks: IMessageCallbackEntry[] = [];

    //
    // Callbacks invoked when a task emits any message, regardless of type.
    //
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    //
    // Tasks waiting to be dispatched to a worker (FIFO).
    //
    private pendingTasks: ITask<any>[] = [];

    //
    // All known tasks (pending + running), keyed by task ID.
    // Used to reconstruct result metadata when a task completes.
    //
    private taskMap: Map<string, ITask<any>> = new Map();

    //
    // Per-source callbacks fired when a task is added via addTask.
    //
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    //
    // Per-source callbacks fired when cancelTasks is called for that source.
    //
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    //
    // Callback that forwards worker log messages to the main-process logger.
    //
    private workerLogCallback: (message: any) => void;

    //
    // Callbacks invoked when a worker requests a toast notification in the renderer.
    //
    private showNotificationCallbacks: Array<(data: IWorkerShowNotificationMessage) => void> = [];

    //
    // Set to true during shutdown so worker exit events are not treated as crashes.
    //
    private isShuttingDown: boolean = false;

    //
    // Creates a new worker pool with the specified number of utility process workers
    //
    constructor(workerPath: string, maxWorkers: number, taskTimeout: number, backendOptions: IWorkerPoolOptions, workerLogCallback: (message: any) => void) {
        this.workerPath = workerPath;
        this.maxWorkers = maxWorkers;
        this.taskTimeout = taskTimeout;
        this.backendOptions = backendOptions;
        this.workerLogCallback = workerLogCallback;
    }

    //
    //
    // Adds a task to the pending queue and attempts to dispatch it immediately.
    //
    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? randomUUID();
        const task: ITask<any> = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            source,
            createdAt: new Date(),
        };
        this.pendingTasks.push(task);
        this.taskMap.set(id, task);

        const callbacks = this.taskAddedCallbacks.get(source);
        if (callbacks) {
            for (const cb of callbacks) {
                cb(id);
            }
        }

        this.tryDispatchPending();
        return id;
    }

    //
    // Registers a callback that fires when a task with the given source is added.
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
    // Tries to dispatch all pending tasks to available workers.
    //
    private tryDispatchPending(): void {
        while (this.pendingTasks.length > 0) {
            const task = this.pendingTasks[0];
            if (!this.dispatchTask(task)) {
                break;
            }
            this.pendingTasks.shift();
        }
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): () => void {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): () => void {
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
    // Registers a callback that will be called for any task message, regardless of type.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): () => void {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Registers a callback that will be called when a worker sends a show-notification message.
    //
    onShowNotification(callback: (data: IWorkerShowNotificationMessage) => void): UnsubscribeFn {
        this.showNotificationCallbacks.push(callback);
        return () => {
            const index = this.showNotificationCallbacks.indexOf(callback);
            if (index !== -1) {
                this.showNotificationCallbacks.splice(index, 1);
            }
        };
    }

    //
    // Invokes all registered completion callbacks with the task result.
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
    // Invokes all registered message callbacks with the task message.
    // Only callbacks that match the message type (if specified) will be invoked.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
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
            catch (error: any) {
                console.error("Error in task message callback:", error);
            }
        }

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
    // Creates a new utility process worker and sets up message handlers
    //
    private createWorker(): IWorkerState {
        const workerEnv: Record<string, string> = {};

        // Pass through temp directory environment variables
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }

        const workerId = this.workers.length + 1;
        const workerOptions: IWorkerOptions = {
            ...this.backendOptions,
            workerId,
        };
        workerEnv.WORKER_OPTIONS = JSON.stringify(workerOptions);

        const worker = utilityProcess.fork(this.workerPath, [], { env: workerEnv });
        const workerState: IWorkerState = {
            worker,
            workerId,
            isReady: false,
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
            taskStartTime: null,
        };

        worker.on('message', (message: any) => {
            this.handleWorkerMessage(workerState, message).catch((error: any) => {
                console.error("Error handling worker message", error);
            });
        });

        worker.on('spawn', () => {
            console.log(`Worker ${workerState.workerId} spawned`);
        });

        worker.on('exit', (code) => {
            // During shutdown, workers are terminated normally - don't treat as crash
            if (this.isShuttingDown) {
                return;
            }
            
            if (code !== 0) {
                console.error(`Worker ${workerState.workerId} exited with code ${code}`);
            }
            this.handleWorkerCrash(workerState);
        });

        this.workers.push(workerState);
        return workerState;
    }

    //
    // Handles messages from utility process workers (ready, task-completed, task-message)
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: any): Promise<void> {
        // Handle worker ready message
        if (data.type === "worker-ready") {
            workerState.isReady = true;
            workerState.isIdle = true;
            this.tryDispatchPending();
            return;
        }

        // Handle task result (both success and failure)
        if (data.type === "task-completed") {
            const { taskId, result } = data;

            // Clear timeout since task completed
            const timeout = this.taskTimeouts.get(taskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(taskId);
            }

            const task = this.taskMap.get(taskId);
            this.taskMap.delete(taskId);

            // Determine if task failed
            const isFailed = result.status === "failed";
            
            // Build result object
            const fullResult: ITaskResult = {
                taskId: taskId,
                status: isFailed ? TaskStatus.Failed : TaskStatus.Succeeded,
                type: task?.type ?? "",
                inputs: task?.data,
            };

            if (isFailed) {
                let deserializedError: Error | undefined;
                if (result.error) {
                    try {
                        deserializedError = deserializeError(result.error);
                    }
                    catch {
                        throw new Error(`Failed to deserialize error: ${typeof result.error === 'string' ? result.error : JSON.stringify(result.error)}`);
                    }
                }
                else {
                    throw new Error("Task failed but no error provided");
                }
                fullResult.error = deserializedError;
                fullResult.errorMessage = deserializedError.message || "Unknown error";
            }
            else {
                fullResult.outputs = result.outputs;
            }

            // Update worker state
            workerState.isIdle = true;
            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            workerState.tasksProcessed++;

            await this.notifyCompletionCallbacks(fullResult);

            // Broadcast completion to all workers so worker-side TaskQueue instances
            // (e.g. in orchestrator tasks) can react to child task completions.
            for (const worker of this.workers) {
                worker.worker.postMessage({ type: "task-completed", taskId, result: fullResult });
            }

            this.tryDispatchPending();
            return;
        }

        // Handle task messages
        if (data.type === "task-message") {
            const { taskId, message } = data;

            // Notify message callbacks
            await this.notifyMessageCallbacks(taskId, message);
            return;
        }

        if (data.type === "log") {
            this.workerLogCallback(data);
            return;
        }

        if (data.type === "show-notification") {
            const msg = data as IWorkerShowNotificationMessage;
            for (const callback of this.showNotificationCallbacks) {
                callback(msg);
            }
            return;
        }

        // Handle queue-task request from worker
        if (data.type === "queue-task") {
            const msg = data as IWorkerQueueTaskMessage;
            this.addTask(msg.taskType, msg.data, msg.source, msg.taskId);
            return;
        }
    }

    //
    // Handles task timeout by marking the task as failed and killing the worker
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        console.error(`[Task Queue] Task ${taskId} timed out after ${this.taskTimeout}ms`);

        // Terminate the worker
        try {
            workerState.worker.kill();
        }
        catch (error: any) {
            console.error(`[Task Queue] Error killing worker ${workerState.workerId}`, error);
        }

        const error = new Error("Task timeout");
        const task = this.taskMap.get(taskId);
        this.taskMap.delete(taskId);
        const result: ITaskResult = {
            taskId: taskId,
            status: TaskStatus.Failed,
            error: error,
            errorMessage: error.message,
            type: task?.type ?? "",
            inputs: task?.data,
        };

        workerState.isIdle = true;
        workerState.currentTaskId = null;
        workerState.currentTaskType = null;
        workerState.currentTaskRunningTimeMs = null;
        workerState.taskStartTime = null;

        await this.notifyCompletionCallbacks(result);

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Handles worker crashes by terminating the worker and creating a replacement.
    // If the worker had a task, it will be requeued.
    //
    private handleWorkerCrash(workerState: IWorkerState): void {
        const crashedTaskId = workerState.currentTaskId;

        // Terminate the crashed worker
        try {
            workerState.worker.kill();
        }
        catch (e) {
            // Worker may already be terminated
        }

        // If worker had a task, clear its timeout and mark as failed
        if (crashedTaskId) {
            const timeout = this.taskTimeouts.get(crashedTaskId);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(crashedTaskId);
            }

            const error = new Error("Worker crashed");
            const task = this.taskMap.get(crashedTaskId);
            this.taskMap.delete(crashedTaskId);
            const result: ITaskResult = {
                taskId: crashedTaskId,
                status: TaskStatus.Failed,
                error: error,
                errorMessage: error.message,
                type: task?.type ?? "",
                inputs: task?.data,
            };

            workerState.currentTaskId = null;
            workerState.currentTaskType = null;
            workerState.currentTaskRunningTimeMs = null;
            workerState.taskStartTime = null;
            this.notifyCompletionCallbacks(result);
        }

        // Replace the worker
        this.replaceWorker(workerState);
    }

    //
    // Replaces a worker with a new one
    //
    private replaceWorker(oldWorkerState: IWorkerState): void {
        // Remove from workers array
        const index = this.workers.indexOf(oldWorkerState);
        if (index > -1) {
            this.workers.splice(index, 1);
        }

        // Create replacement worker
        const workerEnv: Record<string, string> = {};

        // Pass through temp directory environment variables
        if (process.env.TEMP) {
            workerEnv.TEMP = process.env.TEMP;
        }
        if (process.env.TMP) {
            workerEnv.TMP = process.env.TMP;
        }
        if (process.env.TMPDIR) {
            workerEnv.TMPDIR = process.env.TMPDIR;
        }

        const workerOptions: IWorkerOptions = {
            ...this.backendOptions,
            workerId: oldWorkerState.workerId,
        };
        workerEnv.WORKER_OPTIONS = JSON.stringify(workerOptions);

        const worker = utilityProcess.fork(this.workerPath, [], { env: workerEnv });
        const newWorkerState: IWorkerState = {
            worker,
            workerId: oldWorkerState.workerId,
            isReady: false,
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: oldWorkerState.tasksProcessed,
            taskStartTime: null,
        };

        worker.on('message', (message: any) => {
            this.handleWorkerMessage(newWorkerState, message).catch((error: any) => {
                console.error("Error handling worker message", error);
            });
        });

        worker.on('spawn', () => {
            console.log(`Worker ${newWorkerState.workerId} spawned`);
        });

        worker.on('exit', (code) => {
            // During shutdown, workers are terminated normally - don't treat as crash
            if (this.isShuttingDown) {
                return;
            }
            
            if (code !== 0) {
                console.error(`Worker ${newWorkerState.workerId} exited with code ${code}`);
            }
            this.handleWorkerCrash(newWorkerState);
        });

        this.workers.push(newWorkerState);
    }

    //
    // Dispatches a single task to an available worker.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    private dispatchTask(task: ITask<any>): boolean {
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
            const workersNeeded = 1 - workersNotReadyYet; 
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
            return false;
        }
        
        if (!availableWorker) {
            return false; // All workers busy or not ready yet
        }

        availableWorker.isIdle = false;
        availableWorker.currentTaskId = task.id;
        availableWorker.currentTaskType = task.type;
        availableWorker.taskStartTime = Date.now();

        // Set up timeout for this task
        const timeoutId = setTimeout(() => {
            this.handleTaskTimeout(task.id, availableWorker!).catch((error: any) => {
                console.error("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(task.id, timeoutId);

        // Send task to worker
        try {
            const executeMessage: IWorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
                source: task.source,
            };
            availableWorker.worker.postMessage(executeMessage);
        }
        catch (error: any) {
            console.error(`Error sending task to worker ${availableWorker.workerId}`, error);
            const timeout = this.taskTimeouts.get(task.id);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(task.id);
            }
            this.handleWorkerCrash(availableWorker);
            return false;
        }

        return true;
    }

    //
    // Drops pending tasks with the given source and signals running tasks to cancel.
    //
    cancelTasks(source: string): void {
        this.pendingTasks = this.pendingTasks.filter(task => {
            if (task.source === source) {
                this.taskMap.delete(task.id);
                return false;
            }
            return true;
        });

        const cancelMsg: IWorkerCancelTasksMessage = {
            type: "cancel-tasks",
            source,
        };
        for (const workerState of this.workers) {
            workerState.worker.postMessage(cancelMsg);
        }

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
    // Shuts down the worker pool and cleans up resources by terminating all workers
    //
    shutdown(): void {
        // Set shutdown flag to prevent exit handlers from treating normal termination as crashes
        this.isShuttingDown = true;
        
        // Clear all timeouts first to prevent any timeout callbacks from running
        for (const timeout of this.taskTimeouts.values()) {
            clearTimeout(timeout);
        }
        this.taskTimeouts.clear();

        for (const worker of this.workers) {
            try {
                worker.worker.kill();
            }
            catch (error) {
                console.error('Error killing worker:', error);
            }
        }
        this.workers = [];
    }
}

