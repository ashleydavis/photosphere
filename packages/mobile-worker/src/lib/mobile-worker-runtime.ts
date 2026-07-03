import { ITaskContext, executeTaskHandler } from "task-queue";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { IHost, buildHost } from "./host-functions";

//
// The worker API exposed to native code as `globalThis.__photosphereWorker`.
//
export interface IWorkerApi {
    // Runs a task by type with JSON-encoded input, returning a JSON-encoded result.
    runTask: (taskId: string, type: string, dataJson: string) => Promise<string>;
}

declare global {
    //
    // The native host bridge, installed by the native plugin before `runTask` is called.
    //
    var host: IHost | undefined;

    //
    // The embedded worker entry point, assigned by `installWorkerGlobal`.
    //
    var __photosphereWorker: IWorkerApi | undefined;
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
    const data = JSON.parse(dataJson);
    const context = createTaskContext(taskId, host);
    const result = await executeTaskHandler(type, data, context);
    return JSON.stringify(result);
}

//
// Assigns the worker API to `globalThis.__photosphereWorker` so native code can
// call `runTask`. The name `__photosphereWorker` is used (never `Worker`) so it
// cannot shadow the built-in Web Worker constructor or collide in the parity
// harnesses.
//
export function installWorkerGlobal(): void {
    globalThis.__photosphereWorker = { runTask };
}
