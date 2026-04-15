import { log } from "utils";
import { ITask, ITaskResult, WorkerTaskCompletionCallback, TaskMessageCallback, TaskStatus, IMessageCallbackEntry, IQueueBackend, UnsubscribeFn } from "task-queue";
import { randomUUID } from "node:crypto";
import { initTaskHandlers } from "api";

//
// Options passed to workers for context initialization
//
export interface IWorkerOptions {
    // Unique numeric identifier assigned to this worker.
    workerId: number;

    // Whether verbose logging is enabled.
    verbose?: boolean;

    // Whether tool output logging is enabled.
    tools?: boolean;

    // Session identifier forwarded to task handlers.
    sessionId?: string;
}

//
// Worker state interface
//
interface IWorkerState {
    // The underlying Bun Worker thread.
    worker: Worker;

    // Unique numeric identifier assigned to this worker for logging and options.
    workerId: number;

    // Worker has sent "ready" message and can process tasks.
    isReady: boolean;

    // Worker is ready and not currently processing a task.
    isIdle: boolean;

    // ID of the task currently being processed, or null if idle.
    currentTaskId: string | null;

    // Type of the task currently being processed, or null if idle.
    currentTaskType: string | null;

    // Elapsed milliseconds for the current task, updated on status polls, or null if idle.
    currentTaskRunningTimeMs: number | null;

    // Number of tasks this worker has completed (successful or failed).
    tasksProcessed: number;

    // Timestamp (Date.now()) when the current task started, or null if idle.
    taskStartTime: number | null;
}

//
// Options passed to workers for context initialization (does not include workerId, which is assigned per worker)
//
export interface IWorkerPoolOptions {
    // Enable verbose logging in worker threads.
    verbose?: boolean;

    // Enable tool support in worker threads.
    tools?: boolean;

    // Session identifier forwarded to workers for context initialization.
    sessionId?: string;
}

//
// Worker message interface for communication between main thread and workers
//
export interface IWorkerMessage {
    // Discriminant for the message union; always "execute".
    type: "execute";

    // Unique identifier for the task being dispatched.
    taskId: string;

    // Handler name that the worker uses to look up the task implementation.
    taskType: string;

    // Input payload for the task handler.
    data: any;

    // Source tag of the task, used to match cancellation signals.
    source: string;
}

//
// Message sent from main thread to worker to cancel tasks with a given source.
//
export interface IWorkerCancelTasksMessage {
    // Discriminant for the message union; always "cancel-tasks".
    type: "cancel-tasks";

    // Source tag identifying which group of tasks should be cancelled.
    source: string;
}

//
// Worker response message types
//
export interface IWorkerReadyMessage {
    // Discriminant for the message union; always "worker-ready".
    type: "worker-ready";
}

export interface IWorkerTaskCompletedMessage {
    // Discriminant for the message union; always "task-completed".
    type: "task-completed";

    // ID of the task that finished.
    taskId: string;

    // Outcome of the task, including status, error, and output data.
    result: ITaskResult;
}

export interface IWorkerTaskMessage {
    // Discriminant for the message union; always "task-message".
    type: "task-message";

    // ID of the task that sent the message.
    taskId: string;

    // Arbitrary payload emitted by the task handler mid-execution.
    message: any;
}

//
// Message sent from worker to main thread to request queuing a new task.
//
export interface IWorkerQueueTaskMessage {
    //
    // The type of the message.
    //
    type: "queue-task";

    //
    // Pre-assigned task ID from the worker-side TaskQueue, so the main thread uses the same ID.
    // This enables the main thread to forward task-completed back to the correct worker by origin.
    //
    taskId: string;

    //
    // Specifies the handler to use when running the task.
    //
    taskType: string;

    //
    // Input data for the task.
    //
    data: any;

    //
    // Source tag to associate the new task with a logical group (e.g. database path).
    //
    source: string;

}

//
// Union of all message types that a worker thread can send to the main thread.
//
type IWorkerResponseMessage = IWorkerReadyMessage | IWorkerTaskCompletedMessage | IWorkerTaskMessage | IWorkerQueueTaskMessage;

//
// Manages workers on Bun.
//
export class WorkerPoolBun implements IQueueBackend {

    // All currently allocated worker threads.
    private workers: IWorkerState[] = [];

    // Maximum number of worker threads allowed.
    private maxWorkers: number;

    // Options forwarded to each worker thread for logging and session initialization.
    private workerOptions: IWorkerPoolOptions;

    // Milliseconds before a running task is considered timed out.
    private taskTimeout: number;

    // Active timeout handles keyed by task ID, cleared when the task completes.
    private taskTimeouts: Map<string, NodeJS.Timeout> = new Map();

    // Callbacks notified when any task completes (success or failure).
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];

    // Callbacks notified for task messages of a specific type.
    private messageCallbacks: IMessageCallbackEntry[] = [];

    // Callbacks notified for every task message regardless of type.
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    // Tasks waiting to be dispatched to a worker.
    private pendingTasks: ITask<any>[] = [];

    // Maps task ID to task for result construction.
    private taskMap: Map<string, ITask<any>> = new Map();

    // Callbacks registered per source via onTaskAdded.
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();

    // Callbacks registered per source via onTasksCancelled.
    private tasksCancelledCallbacks: Map<string, (() => void)[]> = new Map();

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    // workerOptions: Options to pass to workers for logging and context initialization.
    //
    constructor(maxWorkers: number, taskTimeout: number, workerOptions: IWorkerPoolOptions) {
        this.maxWorkers = maxWorkers;
        this.taskTimeout = taskTimeout;
        this.workerOptions = workerOptions;
        initTaskHandlers();
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
        const entry = { messageType, callback: callback };
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
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", error);
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
        
        // Notify callbacks registered for specific message types
        for (const { messageType: filterType, callback } of this.messageCallbacks) {
            if (messageType !== filterType) {
                continue;
            }
            
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in task message callback", error);
            }
        }
        
        // Notify callbacks registered for any message type
        for (const callback of this.anyMessageCallbacks) {
            try {
                await callback({ taskId, message });
            }
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in any task message callback", error);
            }
        }
    }

    //
    // Creates a single worker and adds it to the pool.
    // Returns the worker state.
    //
    private createWorker(): IWorkerState {
        const env: any = process.env;

        const workerId = this.workers.length + 1;
        const workerOptions: IWorkerOptions = {
            ...this.workerOptions,
            workerId,
        };
        env.WORKER_OPTIONS = JSON.stringify(workerOptions);
        
        const worker = new Worker("./worker.ts", { env });
        const workerState: IWorkerState = {
            worker,
            workerId,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false, // Will be set to true when worker is ready and idle
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: 0,
            taskStartTime: null,
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(workerState, event.data as IWorkerResponseMessage).catch((error: any) => {
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
        return workerState;
    }


    //
    // Replaces a worker with a new one.
    //
    private replaceWorker(oldWorkerState: IWorkerState): void {
        // Remove from workers array
        const index = this.workers.indexOf(oldWorkerState);
        if (index > -1) {
            this.workers.splice(index, 1);
        }

        const env: any = process.env;

        const workerId = oldWorkerState.workerId;
        const workerOptions: IWorkerOptions = {
            ...this.workerOptions,
            workerId,
        };
        env.WORKER_OPTIONS = JSON.stringify(workerOptions);
        
        const worker = new Worker("./worker.ts", { env });
        const newWorkerState: IWorkerState = {
            worker,
            workerId,
            isReady: false, // Will be set to true when worker sends "ready" message
            isIdle: false,
            currentTaskId: null,
            currentTaskType: null,
            currentTaskRunningTimeMs: null,
            tasksProcessed: oldWorkerState.tasksProcessed, // Preserve task count when replacing worker
            taskStartTime: null,
        };

        worker.addEventListener("message", (event: MessageEvent) => {
            this.handleWorkerMessage(newWorkerState, event.data as IWorkerResponseMessage).catch((error: any) => {
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
    }

    //
    // Handles messages from worker threads.
    // Processes task results and errors.
    //
    private async handleWorkerMessage(workerState: IWorkerState, data: IWorkerResponseMessage): Promise<void> {
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

            // Build result object
            const fullResult: ITaskResult = {
                taskId: taskId,
                status: result.status,
                error: result.error,
                errorMessage: result.error?.message || "Unknown error",
                outputs: result.outputs,
                type: task?.type ?? "",
                inputs: task?.data,
            };

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

        // Handle task message
        if (data.type === "task-message") {
            const { taskId, message } = data;
            await this.notifyMessageCallbacks(taskId, message);
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
    // Handles task timeout by terminating the worker and marking the task as failed.
    //
    private async handleTaskTimeout(taskId: string, workerState: IWorkerState): Promise<void> {
        // Clear the timeout (should already be cleared, but be safe)
        const timeout = this.taskTimeouts.get(taskId);
        if (timeout) {
            clearTimeout(timeout);
            this.taskTimeouts.delete(taskId);
        }

        log.error(`[Task Queue] Task ${taskId} timed out after ${this.taskTimeout}ms`);

        // Terminate the worker
        try {
            workerState.worker.terminate();
        } 
        catch (error: any) {
            log.exception(`[Task Queue] Error terminating worker ${workerState.workerId}`, error);
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
            workerState.worker.terminate();
        } catch (e) {
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
    // Dispatches a single task to an available worker.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    private dispatchTask(task: ITask<any>): boolean {

        //
        // Find an available idle worker that has processed the least tasks
        //
        const idleWorkers = this.workers.filter(w => w.isIdle);
        let availableWorker = idleWorkers.length > 0
            ? idleWorkers.reduce((least, current) => 
                current.tasksProcessed < least.tasksProcessed ? current : least
            )
            : undefined;
        
        //
        // If no idle worker available and we haven't reached maxWorkers, create workers for pending tasks
        //
        if (!availableWorker && this.workers.length < this.maxWorkers) {
            
            // Calculate how many workers we need: pending tasks minus workers that will become available
            const workersNeeded = 1; 
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
                log.exception("Error handling task timeout", error);
            });
        }, this.taskTimeout);
        this.taskTimeouts.set(task.id, timeoutId);

        // Send task to worker
        try {
            const executeMsg: IWorkerMessage = {
                type: "execute",
                taskId: task.id,
                taskType: task.type,
                data: task.data,
                source: task.source,
            };
            availableWorker.worker.postMessage(executeMsg);
        } 
        catch (error: any) {
            log.exception(`Error sending task to worker ${availableWorker.workerId}`, error);

            // Clear timeout on error
            const timeout = this.taskTimeouts.get(task.id);
            if (timeout) {
                clearTimeout(timeout);
                this.taskTimeouts.delete(task.id);
            }
            this.handleWorkerCrash(availableWorker);
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
    // Shuts down all the workers.
    //
    shutdown(): void {
        // Clear all timeouts first to prevent any timeout callbacks from running
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