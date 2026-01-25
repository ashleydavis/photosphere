import { ITimestampProvider, IUuidGenerator, log } from "utils";
import { ITask, ITaskResult, IWorkerBackend, TaskMessageCallback, TaskStatus, UnsubscribeFn } from "./worker-backend";

//
// Task completion callback for users
// Can be synchronous or asynchronous
// Receives the task and result as separate parameters
// TInputs types the task.data field, TOutputs types the result.outputs field
//
export type TaskCompletionCallback<TInputs = any, TOutputs = any> = (task: ITask<TInputs>, result: ITaskResult & { outputs?: TOutputs }) => void | Promise<void>;

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
// Task queue interface
//
export interface ITaskQueue {
    //
    // Adds a task to the queue to be run. Returns uuid of the task.
    // If taskId is provided, it will be used instead of generating a new one.
    //
    addTask(type: string, data: any, taskId?: string): string;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    //
    onTaskComplete<TInputs, TOutputs>(callback: TaskCompletionCallback<TInputs, TOutputs>): void;

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // The callback receives the task ID and the message data.
    // Only messages with the specified messageType will be passed to the callback.
    //
    onTaskMessage<TMessage>(messageType: string, callback: TaskMessageCallback): void;

    //
    // Registers a callback that will be called for any task message, regardless of type.
    // The callback receives the task ID and the message data.
    //
    onAnyTaskMessage<TMessage>(callback: TaskMessageCallback): void;

    //
    // Awaits the completion of all tasks and an empty queue.
    //
    awaitAllTasks(): Promise<void>;

    //
    // Gets the status of the queue: number of pending tasks, successful tasks, failed tasks, etc.
    // Includes execution statistics: tasks queued, peak workers, completed, and failed.
    //
    getStatus(): IQueueStatus;

    //
    // Shuts down the task queue and cleans up queue-specific resources.
    // Note: This does NOT shut down the worker backend.
    //
    shutdown(): void;
}

//
// Provider object that creates and manages task queues.
//
export interface ITaskQueueProvider {
    create(): Promise<ITaskQueue>;
}

//
// Generic task queue implementation with an abstraction for workers.
//
export class TaskQueue implements ITaskQueue {
    private tasks: Map<string, ITask<any>> = new Map();
    private pendingTasks: string[] = [];
    private uuidGenerator: IUuidGenerator;
    private timestampProvider: ITimestampProvider;
    private allTasksResolvers: Array<{ resolve: () => void; reject: (error: Error) => void }> = [];

    private completionCallbacks: TaskCompletionCallback<any, any>[] = [];
    private messageCallbacks: Array<{ messageType: string; callback: TaskMessageCallback }> = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];

    private tasksQueued: number = 0;
    private tasksPending: number = 0;
    private tasksRunning: number = 0;
    private tasksCompleted: number = 0;
    private tasksFailed: number = 0;
    private workerBackend: IWorkerBackend;
    private unsubscribeFunctions: UnsubscribeFn[] = [];

    //
    // Creates a new task queue with the specified number of workers.
    // Tasks will execute in separate Bun worker threads for true parallelism.
    // taskTimeout: Timeout in milliseconds for tasks (default: 10 minutes = 600000ms).
    // workerOptions: Options to pass to workers for logging and context initialization.
    //
    constructor(uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider, taskTimeout: number, workerBackend: IWorkerBackend) {
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        this.workerBackend = workerBackend;
        this.unsubscribeFunctions.push(
            this.workerBackend.onTaskComplete((result: ITaskResult) => {
                this.notifyCompletionCallbacks(result);
            })
        );
        this.unsubscribeFunctions.push(
            this.workerBackend.onAnyTaskMessage(message => {
                this.notifyMessageCallbacks(message.taskId, message.message);
            })
        );
        this.unsubscribeFunctions.push(
            this.workerBackend.onWorkerAvailable(() => {
                this.dispatchNextTask();
            })
        );
    }

    //
    // Adds a task to the queue to be executed. Returns the task ID (UUID).
    // The task will be executed when a worker becomes available.
    //
    addTask(type: string, data: any, taskId?: string): string {
        const id = taskId || this.uuidGenerator.generate();

        const task: ITask<any> = {
            id,
            type,
            status: TaskStatus.Pending,
            data,
            createdAt: this.timestampProvider.dateNow()
        };

        this.tasks.set(id, task);
        this.pendingTasks.push(id);
        this.tasksQueued++;
        this.tasksPending++;
        this.dispatchNextTask();

        return id;
    }

    //
    // Registers a callback that will be invoked whenever any task completes (success or failure).
    // Multiple callbacks can be registered and will all be called.
    //
    onTaskComplete<TInputs, TOutputs>(callback: TaskCompletionCallback<TInputs, TOutputs>): void {
        this.completionCallbacks.push(callback as TaskCompletionCallback<any, any>);
    }

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage<TMessage>(messageType: string, callback: TaskMessageCallback): void {
        this.messageCallbacks.push({ messageType, callback });
    }

    //
    // Registers a callback that will be called for any task message, regardless of type.
    //
    onAnyTaskMessage<TMessage>(callback: TaskMessageCallback): void {
        this.anyMessageCallbacks.push(callback);
    }

    //
    // Waits for all pending and running tasks to complete.
    // Resolves when the queue is empty (no pending or running tasks).
    //
    async awaitAllTasks(): Promise<void> {
        if (this.tasksPending === 0 && this.tasksRunning === 0) {
            return;
        }

        return new Promise<void>((resolve, reject) => {
            this.allTasksResolvers.push({ resolve, reject });
            this.checkAllTasksComplete();
        });
    }

    //
    // Gets a summary of the queue status: counts of pending, running, completed, and failed tasks.
    // Includes execution statistics: tasks queued, peak workers, completed, and failed.
    // Useful for monitoring and progress tracking.
    //
    getStatus() {
        return {
            pending: this.tasksPending,
            running: this.tasksRunning,
            completed: this.tasksCompleted,
            failed: this.tasksFailed,
            total: this.tasksQueued,
        };
    }

    //
    // Dispatches the next pending task if a worker is available.
    // Called automatically when tasks are added or completed.
    //
    private dispatchNextTask(): void {
        if (this.pendingTasks.length === 0) {
            this.checkAllTasksComplete();
            return;
        }

        const taskId = this.pendingTasks[0];
        const task = this.tasks.get(taskId);
        if (!task) {
            return;
        }

        if (this.workerBackend.dispatchTask(task)) {
            // Remove the worker from the queue.
            this.pendingTasks.shift();

            // Mark task as running and assign to worker
            task.status = TaskStatus.Running;
            task.startedAt = this.timestampProvider.dateNow();
            this.tasksPending--;
            this.tasksRunning++;
        }
    }

    //
    // Invokes all registered completion callbacks with the task result.
    // Callback errors are caught and logged to prevent breaking the queue.
    // Async callbacks are awaited to ensure they complete.
    //
    private async notifyCompletionCallbacks(result: ITaskResult): Promise<void> {

        const task = this.tasks.get(result.taskId);
        if (!task) {
            return;
        }

        // Determine if task failed
        const isFailed = result.status === "failed";
            
        // Update task status
        task.status = isFailed ? TaskStatus.Failed : TaskStatus.Succeeded;
        task.completedAt = this.timestampProvider.dateNow();
        this.tasksRunning--;

        if (isFailed) {
            this.tasksFailed++;
        }
        else {
            this.tasksCompleted++;
        }

        // Call user callbacks with task and result as separate parameters
        for (const callback of this.completionCallbacks) {
            try {
                await callback(task, result);
            } 
            catch (error: any) {
                // Don't let callback errors break the task queue
                log.exception("Error in task completion callback", error);
            }
        }

        this.checkAllTasksComplete();
        this.tasks.delete(result.taskId);
        this.dispatchNextTask();
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
    // Internal: Checks if all tasks are complete and resolves awaitAllTasks() if so.
    // Called after each task completes.
    //
    private checkAllTasksComplete(): void {
        if (this.pendingTasks.length === 0 && this.workerBackend.isIdle() && this.allTasksResolvers.length > 0) {
            const resolvers = this.allTasksResolvers;
            this.allTasksResolvers = [];
            for (const resolver of resolvers) {
                resolver.resolve();
            }
        }
    }

    //
    // Shuts down the task queue and cleans up queue-specific resources.
    // Clears all tasks, pending tasks, and callbacks.
    // Unsubscribes from worker backend events.
    // Note: This does NOT shut down the worker backend. Worker backend shutdown
    // should be handled separately by the code that manages the backend lifecycle.
    //
    shutdown(): void {
        // Unsubscribe from worker backend events
        for (const unsubscribe of this.unsubscribeFunctions) {
            unsubscribe();
        }
        this.unsubscribeFunctions = [];
        
        this.tasks.clear();
        this.pendingTasks = [];
        this.messageCallbacks = [];
        this.anyMessageCallbacks = [];
        this.completionCallbacks = [];
    }
}



