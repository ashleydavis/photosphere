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
}

//
// Task handler function type
// Returns the result payload (can be any type)
//
export type TaskHandler = (data: any, context: ITaskContext) => Promise<any>;

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
//
export interface ITaskMessageData {
    //
    // The ID of the task that sent this message.
    //
    taskId: string;

    //
    // The message payload.
    //
    message: any;
}

//
// Callback invoked when a task sends an arbitrary message to the client.
//
export type TaskMessageCallback = (data: ITaskMessageData) => void | Promise<void>;

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

