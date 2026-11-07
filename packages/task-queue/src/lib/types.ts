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
// Names the user-visible job a task belongs to.
//
// Whatever queues the task puts this in the task's input data, and the task's handler echoes it back
// in the progress it reports. That echo is how the interface finds out about work it did not queue
// itself: a background sync is queued by the desktop's main process and by the mobile app's native
// sync driver, and the only thing either of those sends the interface is the task's own messages.
//
export interface IJobTag {
    //
    // Groups every task of this job. The interface shows one row per id, and drops the row when the
    // last task carrying this id has completed.
    //
    id: string;

    //
    // What the row is called, for example "Importing photos".
    //
    name: string;

    //
    // The task source to cancel to stop this job, which is what the Cancel button passes to
    // cancelTasks(). Left out when the job cannot be cancelled from the interface: a background sync
    // is queued under a source chosen by the host, which the task that plans the sync does not know,
    // so it says so by leaving this out rather than by guessing at one.
    //
    cancelSource?: string;
}

//
// What a task handler reports about the job it is doing.
//
// Sent whenever its progress moves, and carrying the whole job every time, so an interface that was
// not listening when the job started still learns all of it from the next one. That happens on a
// phone, where the system suspends the WebView while the work carries on in the native engine.
//
export interface IJobProgressMessage {
    //
    // Discriminates this from every other task message.
    //
    type: "job-progress";

    //
    // The job this task belongs to, straight from the task's input data.
    //
    job: IJobTag;

    //
    // When the handler started work, in milliseconds since the epoch.
    //
    // The elapsed time the interface shows counts from here rather than from when it first saw the
    // job, so a job that was already running when the app came back to the foreground reports its
    // real age instead of restarting from zero.
    //
    startedAt: number;

    //
    // What the job is doing right now, for example "12 imported, 3 already there".
    //
    // There is deliberately no completion fraction. Most jobs here scan or stream and cannot know
    // one, the interface shows a spinner rather than a bar, and a job made of several tasks has no
    // single honest answer anyway.
    //
    progressMessage?: string;
}

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

