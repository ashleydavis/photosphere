import { Buffer } from "buffer";
import { ITaskContext, executeTaskHandler, ITaskResult, TaskStatus, TaskPriority, WorkerQueueBackend, setQueueBackend } from "task-queue";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { IHost, buildHost } from "./host-functions";

//
// How many child tasks one task may have running at once on a phone.
//
// Two, because the embedded engine pool is small and every engine a task fills is one a tap has to
// wait for. Unbounded, this is what made a database take two minutes and eight seconds to open on a
// Pixel 6 while automatic import was running: the import queued one hash task per file as fast as it
// could scan, and everything else in the app queued up behind them.
//
const MOBILE_MAX_CONCURRENT_CHILD_TASKS = 2;

//
// The worker API exposed to native code as `globalThis.__photosphereWorker`.
//
export interface IWorkerApi {
    // Runs a task by type with JSON-encoded input, returning a JSON-encoded result.
    runTask: (taskId: string, type: string, dataJson: string) => Promise<string>;

    // Delivers a child-task event (completion or streamed message) from native back into this
    // engine so an orchestrator handler awaiting its subtasks can resolve. eventJson is an
    // IChildEvent. Mirrors how the Electron worker receives forwarded "task-completed" messages.
    deliverChildEvent: (eventJson: string) => void;
}

//
// The "queue-task" message the WorkerQueueBackend posts when a handler enqueues a child task.
// It is the only message that backend emits; the mobile runtime routes it to host.queueTask.
//
interface ISubtaskMessage {
    // Discriminant; always "queue-task".
    type: string;

    // The locally-generated id for the child task.
    taskId: string;

    // The handler type name for the child task.
    taskType: string;

    // The input data for the child task.
    data: any;

    // The source tag grouping the child task with its siblings.
    source: string;

    // The priority the child asked for, or undefined to run at the priority of the task that queued
    // it.
    priority?: TaskPriority;
}

//
// The JSON-safe result payload carried by a "completed" child event. Mirrors the JSON subset the
// native pool can marshal (no live Error object): the runtime reconstructs an Error from errorMessage.
//
interface IChildTaskResult {
    // The id of the child task that produced this result.
    taskId: string;

    // Whether the child task succeeded or failed.
    status: TaskStatus;

    // The handler type name of the child task.
    type: string;

    // The input data the child task was queued with.
    inputs: any;

    // The handler output when the child task succeeded.
    outputs?: any;

    // The error message when the child task failed.
    errorMessage?: string;
}

//
// A child-task event delivered from native into the originating engine: either a terminal
// completion or a streamed progress message. Discriminated by `kind`.
//
interface IChildCompletedEvent {
    // Discriminant for a completion event.
    kind: "completed";

    // The child task's result.
    result: IChildTaskResult;
}

//
// A streamed progress message from a running child task, routed to the originating engine.
//
interface IChildMessageEvent {
    // Discriminant for a message event.
    kind: "message";

    // The id of the child task that sent the message.
    taskId: string;

    // The streamed message payload.
    message: any;
}

//
// The union of child-task events native delivers via globalThis.__childEvent.
//
type IChildEvent = IChildCompletedEvent | IChildMessageEvent;

declare global {
    //
    // The native host bridge, installed by the native plugin before `runTask` is called.
    //
    var host: IHost | undefined;

    //
    // The embedded worker entry point, assigned by `installWorkerGlobal`.
    //
    var __photosphereWorker: IWorkerApi | undefined;

    //
    // Inbound child-task event entry point, installed by `installWorkerGlobal`. Native calls this
    // (like __tcpEvent) to deliver a child task's completion or message back into this engine.
    //
    var __childEvent: ((eventJson: string) => void) | undefined;
}

//
// The process-level worker-side queue backend. A handler that enqueues a child task via
// `new TaskQueue(...)` reaches this backend through the global `setQueueBackend` singleton;
// its addTask emits a "queue-task" message that `postSubtaskMessage` routes to native.
//
let workerBackend: WorkerQueueBackend | undefined;

//
// The tag key used to represent a binary value (Buffer/Uint8Array) as base64 across the JSON bridge.
// Task results and inputs cross the native bridge as JSON strings, which cannot represent typed
// arrays (a Uint8Array serialises to {"0":..,"1":..}); Electron/CLI preserve them via structured
// clone. So binary fields are tagged and base64-encoded on the way out and reconstructed on the way
// in, which keeps subtask round trips (e.g. hash-file's hash, upload-asset's expectedHash) correct.
//
const BINARY_TAG = "__u8b64__";

//
// The tag key used to represent a Date as epoch milliseconds across the JSON bridge. Like binary,
// a Date does not survive a plain JSON round trip (JSON.stringify turns it into an ISO string, so
// the receiver gets a string and `.getTime()` fails); Electron/CLI preserve it via structured clone.
//
const DATE_TAG = "__date__";

//
// JSON.stringify replacer that encodes binary (Buffer/Uint8Array) and Date fields into tagged
// objects so they survive the bridge crossing. Uses `this[key]` to read the raw value before the
// value's own toJSON (Buffer -> number object, Date -> ISO string) would run.
//
function bridgeReplacer(this: any, key: string, value: any): any {
    const rawValue = this[key];
    if (rawValue instanceof Uint8Array) {
        return { [BINARY_TAG]: Buffer.from(rawValue).toString("base64") };
    }
    if (rawValue instanceof Date) {
        return { [DATE_TAG]: rawValue.getTime() };
    }
    return value;
}

//
// JSON.parse reviver that reconstructs a tagged binary value into a Buffer (a Uint8Array subclass,
// so it satisfies both Buffer.from and typed-array consumers like `.slice().buffer`) and a tagged
// Date back into a Date.
//
function bridgeReviver(key: string, value: any): any {
    if (value && typeof value === "object") {
        if (typeof value[BINARY_TAG] === "string") {
            return Buffer.from(value[BINARY_TAG], "base64");
        }
        if (typeof value[DATE_TAG] === "number") {
            return new Date(value[DATE_TAG]);
        }
    }
    return value;
}

//
// Routes a WorkerQueueBackend message to native. The backend only ever posts "queue-task", so the
// child task is handed to host.queueTask, which enqueues it on the native engine pool (the mobile
// "main-thread queue"). Any other message type is a programming error.
//
function postSubtaskMessage(message: ISubtaskMessage): void {
    const host = globalThis.host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; cannot queue a child task.");
    }

    if (message.type === "queue-task") {
        host.queueTask(message.taskId, message.taskType, JSON.stringify(message.data, bridgeReplacer), message.source, message.priority ?? null);
        return;
    }

    throw new Error(`Unexpected worker backend message type: ${message.type}`);
}

//
// Installs the worker-side queue backend once as the process-level singleton, so a handler's
// `new TaskQueue(...)` enqueues child tasks back to native instead of throwing.
//
function installQueueBackend(): void {
    if (workerBackend) {
        return;
    }

    workerBackend = new WorkerQueueBackend(postSubtaskMessage, new RandomUuidGenerator());
    setQueueBackend(workerBackend);
}

//
// Delivers a child-task event from native into the worker-side backend so an awaiting
// orchestrator handler resolves. A "completed" event reconstructs an Error from errorMessage
// when the child failed; a "message" event fires the child task's message callbacks.
//
export function deliverChildEvent(eventJson: string): void {
    if (!workerBackend) {
        throw new Error("Worker queue backend is not installed; cannot deliver a child event.");
    }

    const event = JSON.parse(eventJson, bridgeReviver) as IChildEvent;
    if (event.kind === "completed") {
        const childResult = event.result;
        const result: ITaskResult = {
            taskId: childResult.taskId,
            status: childResult.status,
            type: childResult.type,
            inputs: childResult.inputs,
            outputs: childResult.outputs,
            error: childResult.status === TaskStatus.Failed
                ? new Error(childResult.errorMessage ?? "Unknown error")
                : undefined,
            errorMessage: childResult.errorMessage,
        };
        void workerBackend.notifyTaskCompleted(result);
    }
    else {
        void workerBackend.notifyTaskMessage(event.taskId, event.message);
    }
}

//
// Reads the native-installed host bridge and wraps it so every expected host
// function is either the native function or a function that throws NOT IMPLEMENTED.
// The wrapped host is written back to `globalThis.host` so any code that reads the
// global (for example the storage shims) also sees the wrapped functions.
//
function getEffectiveHost(): IHost {
    const rawHost = globalThis.host;
    if (!rawHost) {
        throw new Error("Native host bridge (globalThis.host) is not installed before runTask was called.");
    }

    const effectiveHost = buildHost(rawHost);
    globalThis.host = effectiveHost;
    return effectiveHost;
}

//
// Builds the task context backed by the native host bridge: `sendMessage` and
// `isCancelled` route through native, and `sessionId` comes from the
// plugin-owned host so every task in the pool shares one consistent session.
//
function createTaskContext(taskId: string, host: IHost): ITaskContext {
    const context: ITaskContext = {
        uuidGenerator: new RandomUuidGenerator(),
        timestampProvider: new TimestampProvider(),
        sessionId: host.sessionId,
        taskId,
        sendMessage: (message: any) => {
            host.sendMessage(taskId, JSON.stringify(message));
        },
        isCancelled: () => {
            return host.isCancelled(taskId);
        },
        maxConcurrentChildTasks: MOBILE_MAX_CONCURRENT_CHILD_TASKS,
    };

    return context;
}

//
// Runs a task in the embedded engine: parses the JSON input, builds the
// host-backed task context, dispatches to the registered handler, and returns
// the JSON-encoded result. Input and result cross the native bridge as JSON
// strings.
//
export async function runTask(taskId: string, type: string, dataJson: string): Promise<string> {
    const host = getEffectiveHost();
    const data = JSON.parse(dataJson, bridgeReviver);
    const context = createTaskContext(taskId, host);
    const result = await executeTaskHandler(type, data, context);
    return JSON.stringify(result, bridgeReplacer);
}

//
// Assigns the worker API to `globalThis.__photosphereWorker` so native code can
// call `runTask`. The name `__photosphereWorker` is used (never `Worker`) so it
// cannot shadow the built-in Web Worker constructor or collide in the parity
// harnesses.
//
export function installWorkerGlobal(): void {
    installQueueBackend();
    globalThis.__photosphereWorker = { runTask, deliverChildEvent };
    globalThis.__childEvent = deliverChildEvent;
}
