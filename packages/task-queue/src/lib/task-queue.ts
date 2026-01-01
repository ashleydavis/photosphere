import type { TaskHandler } from "./types";

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
// Task completion callback
// Can be synchronous or asynchronous
//
export type TaskCompletionCallback<TInputs = any, TOutputs = any> = (result: ITaskResult<TInputs, TOutputs>) => void | Promise<void>;

//
// Task message callback
// Called when a task sends arbitrary messages to the client
//
export type TaskMessageCallback<TMessage = any> = (taskId: string, message: TMessage) => void | Promise<void>;

//
// Queue status interface
//
export interface IQueueStatus {
    pending: number;
    running: number;
    completed: number;
    failed: number;
    total: number;
    tasksQueued: number;
    peakWorkers: number;
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
    // Includes execution statistics: tasks queued, peak workers, completed, and failed.
    //
    getStatus(): IQueueStatus;

    //
    // Gets current state of all workers for debugging.
    //
    getWorkerState(): IWorkerInfo[];

    //
    // Sets a callback to be notified when worker state changes.
    //
    onWorkerStateChange(callback: WorkerStateChangeCallback): void;

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // The callback receives the task ID and the message data.
    // If messageType is provided, only messages with that type will be passed to the callback.
    //
    onTaskMessage<TMessage = any>(messageType: string, callback: TaskMessageCallback<TMessage>): void;

    //
    // Shuts down the task queue and terminates all workers.
    //
    shutdown(): void;
}

//
// Provider object that creates and manages task queues.
//
export interface ITaskQueueProvider {
    create(): Promise<ITaskQueue>;
}
