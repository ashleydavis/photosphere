//
// Shared types for task queue system
// These types are used by both the main task queue and worker code
//

import type { IUuidGenerator, ITimestampProvider } from "utils";

//
// Task context with all dependencies needed for task execution
//
export interface ITaskContext {
    //
    // Generates unique identifiers.
    //
    uuidGenerator: IUuidGenerator;

    //
    // Provides the current timestamp.
    //
    timestampProvider: ITimestampProvider;

    //
    // Unique identifier for the session this task belongs to.
    //
    sessionId: string;

    //
    // The unique ID of the currently executing task.
    //
    taskId: string;

    //
    // Sends a message from the task handler back to the caller.
    //
    sendMessage: (message: any) => void;

    //
    // Returns true if this task has been cancelled and should stop as soon as possible.
    //
    isCancelled: () => boolean;

    //
    // How many child tasks this task may have running at once.
    //
    // Supplied by the platform that built this context, because only it knows: a desktop has cores
    // and a fast disk to spare, while every engine an import fills on a phone is one a tap has to
    // wait for. It is not the size of the worker pool, it is how much of that pool one task may take,
    // so a second import, a sync, or anything the user does still gets a worker.
    //
    maxConcurrentChildTasks: number;
}

//
// Task handler function type
// Returns the result payload (can be any type)
//
export type TaskHandler = (data: any, context: ITaskContext) => Promise<any>;

//
// How urgent a task is, which decides the order the queue dispatches pending tasks in.
//
// Two levels are enough. Interactive means the user is sitting in front of the app waiting for this
// to finish (opening a database, reading the database list); background is everything else, and is
// what automatic import and syncing use. Within a level, arrival order is kept.
//
export enum TaskPriority {
    //
    // Something the user is waiting on. Dispatched ahead of every background task, however long
    // those have been queued.
    //
    Interactive = "interactive",

    //
    // Work that happens on its own. Dispatched only when no interactive task is waiting.
    //
    Background = "background"
}

//
// The priority a task runs at when nothing asked for one, and it is not a child of a running task.
//
export const DEFAULT_TASK_PRIORITY = TaskPriority.Background;

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
    //
    // Unique identifier for this task.
    //
    id: string;

    //
    // The type name used to look up the registered handler.
    //
    type: string;

    //
    // Current lifecycle state of the task.
    //
    status: TaskStatus;

    //
    // Input data passed to the task handler.
    //
    data: TData;

    //
    // Source tag used to group and cancel related tasks (e.g. a database path).
    //
    source: string;

    //
    // How urgent the task is. Decides which pending task the pool dispatches next.
    //
    priority: TaskPriority;

    //
    // When the task was created.
    //
    createdAt: Date;

    //
    // When execution started (set by the worker pool when dispatched).
    //
    startedAt?: Date;

    //
    // When execution completed (set by the worker pool on completion).
    //
    completedAt?: Date;
}

//
// Result returned when a task finishes (success or failure).
//
export interface ITaskResult {
    //
    // The ID of the task that produced this result.
    //
    taskId: string;

    //
    // Whether the task succeeded or failed.
    //
    status: TaskStatus;

    //
    // Deserialized error object when status is Failed.
    //
    error?: Error;

    //
    // Convenience field: error?.message || "Unknown error".
    //
    errorMessage?: string;

    //
    // The actual result data returned by the handler.
    //
    outputs?: any;

    //
    // The type of the task that produced this result.
    //
    type: string;

    //
    // The input data passed to the task when it was queued.
    //
    inputs: any;
}

//
// Low-level completion callback used by worker pool implementations.
//
export type WorkerTaskCompletionCallback = (result: ITaskResult) => void | Promise<void>;

//
// Task message data structure passed to message callbacks.
// TMessage gives compile-time typing for the message payload.
//
export interface ITaskMessageData<TMessage = any> {
    //
    // The ID of the task that sent this message.
    //
    taskId: string;

    //
    // The message payload.
    //
    message: TMessage;
}

//
// Callback invoked when a task sends an arbitrary message to the client.
// TMessage gives compile-time typing for the message payload.
//
export type TaskMessageCallback<TMessage = any> = (data: ITaskMessageData<TMessage>) => void | Promise<void>;

//
// Unsubscribe function returned by event listener registrations.
//
export type UnsubscribeFn = () => void;

//
// Typed completion callback for consumers of the task queue.
// TInputs and TOutputs give compile-time types for result.inputs and result.outputs.
//
export type TaskCompletionCallback<TInputs = any, TOutputs = any> = (result: ITaskResult & { inputs: TInputs; outputs?: TOutputs }) => void | Promise<void>;

//
// A registered task message callback entry pairing a message type filter with its callback.
//
export interface IMessageCallbackEntry {
    //
    // The message type this callback is registered for.
    //
    messageType: string;

    //
    // The callback to invoke when a message with the matching type is received.
    //
    callback: TaskMessageCallback;
}

