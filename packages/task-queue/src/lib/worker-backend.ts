//
// Task status enumeration
//
export enum TaskStatus {
    Pending = "pending",
    Running = "running",
    Succeeded = "succeeded",
    Failed = "failed"
}

//
// Task data structure
//
export interface ITask<TData> {
    id: string;
    type: string;
    status: TaskStatus;
    data: TData;
    createdAt: Date;
    startedAt?: Date;
    completedAt?: Date;
}

//
// Task result interface
//
export interface ITaskResult {
    taskId: string;
    status: TaskStatus;
    error?: Error; // Deserialized error object (automatically deserialized from JSON)

    //todo: Is this needed? Surely the error object is enough.
    errorMessage?: string; // Convenience field: error?.message || "Unknown error"
    outputs?: any; // The actual result data returned by the handler
}

//
// Task completion callback
// Can be synchronous or asynchronous
// Worker backends call this with ITaskResult (without task)
//
export type WorkerTaskCompletionCallback = (result: ITaskResult) => void | Promise<void>;

//
// Task message data structure
//
export interface ITaskMessageData {
    taskId: string;
    message: any;
}

//
// Task message callback
// Called when a task sends arbitrary messages to the client
//
export type TaskMessageCallback = (data: ITaskMessageData) => void | Promise<void>;

//
// Interface for managing workers that can be implmented differently on different platforms.
//
export interface IWorkerBackend {
    //
    // Dispatch a task to a worker if possible.
    // Returns true if the task was dispatched, false if no worker was available.
    //
    dispatchTask(task: ITask<any>): boolean;

    //
    // Registers a callback that will be called when a worker becomes available.
    //
    onWorkerAvailable(callback: () => void): void;

    //
    // Registers a callback that will be called when any task completes (success or failure).
    // Worker backends call this with ITaskResult (without task)
    //
    onTaskComplete(callback: WorkerTaskCompletionCallback): void;

    //
    // Registers a callback that will be called when a task sends messages to the client.
    // The callback receives the task ID and the message data.
    // Only messages with the specified messageType will be passed to the callback.
    //
    onTaskMessage(messageType: string, callback: TaskMessageCallback): void;

    //
    // Registers a callback that will be called for any task message, regardless of type.
    // The callback receives the task ID and the message data.
    //
    onAnyTaskMessage(callback: TaskMessageCallback): void;

    //
    // Checks if all workers are idle.
    //
    isIdle(): boolean;

    //
    // Shuts down all the workers.
    //
    shutdown(): void; //todo: Prefer not to expose this.
}

