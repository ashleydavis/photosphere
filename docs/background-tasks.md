# Background Tasks

Background tasks run in a worker thread managed by the `task-queue` package. They handle CPU-heavy or I/O-bound work (database reads, file hashing, sync, import) without blocking the UI.

## How it works

- A `TaskQueue` queues tasks to a backend (`IQueueBackend`).
- The backend dispatches each task to a worker thread that calls the registered handler.
- Results and messages flow back to the caller via callbacks or `await`.

On desktop and CLI the worker thread is a Node/Bun worker. On mobile there is no Node runtime in the app, so the same task code runs inside an embedded JavaScript engine driven from native code. See the mobile section below.

---

## Mobile (embedded JS engine)

> The infrastructure described here (the shared `packages/mobile-frontend` queue backend and platform wiring, the `packages/mobile-worker` runtime and host-bridge machinery, and the native `JsEngine` plugin with its engine pool/dispatcher) is in place. The Node.js APIs the task handlers use are **not** implemented for the engine in this layer: every Node.js call from a background task reports NOT IMPLEMENTED until a later layer supplies the native-backed implementations (storage `fs`, hashing, media tools).

On iOS and Android there is no Node or Bun runtime inside the app, so background tasks cannot run in a Node worker thread. Instead the same TypeScript task code runs inside an embedded JavaScript engine that lives in native code, off the WebView. The engine is JavaScriptCore on iOS and QuickJS on Android. The flow is identical on both platforms; only the engine implementation differs.

### How a task runs on mobile

The TypeScript orchestration in `packages/task-queue` is reused unchanged. The task handlers in `packages/node-api/src/lib/*.worker.ts` are compiled into a single `worker.bundle.js` and executed by the embedded engine. The bundle exposes its entry point by assigning `globalThis.__photosphereWorker = { runTask }` (built with `bun build --format=iife`; no bundler global-name is set, so the two mechanisms cannot collide). The name `__photosphereWorker` is used rather than `Worker` so it does not shadow the built-in Web Worker constructor.

### The round trip

```
TaskQueue.addTask(type, data)            // shared frontend, packages/task-queue
  -> EmbeddedJsQueueBackend               // IQueueBackend implementation for mobile
  -> native JsEngine Capacitor plugin     // pending FIFO + pool dispatcher
  -> embedded engine: globalThis.__photosphereWorker.runTask(...)
  -> executeTaskHandler(...)              // runs the registered handler
  -> results / messages back via notifyListeners("taskCompleted" / "taskMessage")
  -> EmbeddedJsQueueBackend -> TaskQueue onTaskComplete / onTaskMessage
```

`addTask` is fire-and-forget: the task id is generated locally on the frontend (like the Electron `send` path) and returned immediately, because the Capacitor plugin call returns a Promise and cannot be awaited synchronously. The un-awaited dispatch promise's rejection is caught and surfaced as a failed task result for that id, never left as an unhandled rejection.

### Node APIs and the host bridge

**What the host bridge is.** A bare JS engine can compute but cannot touch the device: no files, no hashing, no image or video tools. The host bridge is how the embedded JavaScript reaches native code. When the native plugin starts an engine, it installs one JavaScript object, `globalThis.host`, whose members are native functions (Swift on iOS, Kotlin/Java on Android). The task code calls them (for example `host.fsReadFile(path)`) and the call runs in native and returns. It is the only way out of the otherwise sandboxed engine, so every device interaction goes through a `host.*` function.

A handler may use whatever Node APIs it needs, the same as on desktop or CLI: many import `fs`/`fs/promises`, `stream`, `path`, `crypto`, and `os` directly. The embedded engine has no Node runtime. This infrastructure layer does **not** implement those Node APIs and does not shim them: a background task that calls a Node.js function reports NOT IMPLEMENTED rather than silently doing the wrong thing. Implementing them (native-backed `fs` so `FileStorage` and `node-utils` run unchanged, native file hashing, native image/video tools) is the job of later layers, which add the corresponding `host.*` functions and the build-time wiring that routes the Node calls to them.

The host functions that are genuinely infrastructure — `sendMessage` (stream a progress message) and `isCancelled` (cancellation check) — are installed and working. Every other `host.*` function (hashing, fs, media) reports NOT IMPLEMENTED until its layer lands.

### The NOT IMPLEMENTED rule

Any host function that is not implemented yet must fail loudly, never silently no-op. It throws with the exact message:

```
NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.
```

This is surfaced as the task's error result and logged at error level, so a missing piece is obvious during development.

### Concurrency and cancellation

Tasks run on a pool of engine threads. The pool size is the build constant `POOL_SIZE` (default 3). The native dispatcher keeps a FIFO of pending tasks and assigns each to an idle engine slot; a size-1 pool runs tasks serially. Cancellation is by source: cancelling a source drops its still-pending tasks from the FIFO and signals running tasks via `isCancelled()`. On `shutdown()` the engine threads are torn down and the Capacitor listeners are removed.

### Security notes

- Native storage host functions take path strings supplied by the task code. They are sandboxed to the storage root: `..` segments and absolute paths are rejected.
- `worker.bundle.js` is only ever eval'd from the packaged app asset. It is never loaded from a remote or OTA source.

---

## Adding a new task type

### 1. Create the worker file

Create `packages/api/src/lib/<name>.worker.ts`:

```typescript
import type { ITaskContext } from "task-queue";
import { openStorage } from "./open-storage";

// Input data passed to the task.
export interface IMyTaskData {
    databasePath: string;
    // ... other inputs
}

// Output type returned by the task (becomes result.outputs on completion).
export interface IMyTaskResult {
    // ... fields
}

// The handler runs in a worker thread.
export async function myTaskHandler(
    data: IMyTaskData,
    context: ITaskContext
): Promise<IMyTaskResult> {
    const { storage } = await openStorage(data.databasePath);

    // Use context.isCancelled() in long loops to stop early if cancelled.
    // Use context.sendMessage({ type: "my-progress", ... }) to stream updates.
    // Use context.uuidGenerator / context.timestampProvider / context.sessionId as needed.

    return { /* result fields */ };
}
```

Use `openStorage(databasePath)` to get the storage instance. It handles S3 credentials and encryption keys transparently.

### 2. Register the handler

In `packages/api/src/lib/task-handlers.ts`, add the import and register call:

```typescript
import { myTaskHandler } from "./my-task.worker";

export function initTaskHandlers(): void {
    // ... existing handlers ...
    registerHandler("my-task", myTaskHandler);
}
```

The string `"my-task"` is the type name used when queuing the task. It must be unique.

### 3. Export from the api package (if needed by consumers)

In `packages/api/src/index.ts`:

```typescript
export * from "./lib/my-task.worker";
```

---

## Queuing and consuming a task

```typescript
import { TaskQueue, TaskStatus } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type { IMyTaskData, IMyTaskResult } from "api";

// Create a queue. The source string is used to group and cancel related tasks.
const queue = new TaskQueue(new RandomUuidGenerator(), "my-source");

// Queue the task. Returns the task ID.
const taskId = queue.addTask("my-task", { databasePath } satisfies IMyTaskData);

// Option A: await the result directly.
const result = await queue.awaitTask(taskId);
if (result?.status === TaskStatus.Succeeded) {
    const output = result.outputs as IMyTaskResult;
}

// Option B: subscribe to completion (handles all tasks in the queue).
queue.onTaskComplete<IMyTaskData, IMyTaskResult>((result) => {
    if (result.status === TaskStatus.Succeeded) {
        const output = result.outputs; // typed as IMyTaskResult
    }
});

// Always shut down the queue when done.
queue.shutdown();
```

### In a React component

Use `useRef` to hold the queue across renders and clean up in the `useEffect` return:

```typescript
const queue = useRef<TaskQueue | undefined>(undefined);

useEffect(() => {
    if (!databasePath) {
        return;
    }

    queue.current = new TaskQueue(new RandomUuidGenerator(), `my-task-${databasePath}`);

    const taskId = queue.current.addTask("my-task", { databasePath });
    queue.current.awaitTask(taskId).then(result => {
        if (result?.status === TaskStatus.Succeeded) {
            setData(result.outputs as IMyTaskResult);
        }
        else {
            setError(result?.errorMessage || "Task failed");
        }
    });

    return () => {
        queue.current?.shutdown();
        queue.current = undefined;
    };
}, [databasePath]);
```

---

## Streaming messages from a task

For long-running tasks that report progress or stream batches:

**In the handler:**
```typescript
context.sendMessage({ type: "my-progress", percent: 50 });
```

**In the consumer:**
```typescript
queue.onTaskMessage<IMyProgressMessage>("my-progress", ({ message }) => {
    setProgress(message.percent);
});
```

The `onTaskMessage` filter matches only messages whose `type` field equals the given string.

---

## Key files

| File | Purpose |
|------|---------|
| `packages/api/src/lib/task-handlers.ts` | Registers all handlers; call `initTaskHandlers()` in the worker thread |
| `packages/api/src/lib/open-storage.ts` | Opens a storage instance with credentials and encryption |
| `packages/task-queue/src/lib/task-queue.ts` | `TaskQueue` class — queue tasks, await results, subscribe to messages |
| `packages/task-queue/src/lib/types.ts` | `ITaskContext`, `ITaskResult`, `TaskStatus`, callbacks |

## Existing task types

| Type string | Handler file | Purpose |
|-------------|-------------|---------|
| `"load-assets"` | `load-assets.worker.ts` | Stream all assets from a database |
| `"import-assets"` | `import-assets.worker.ts` | Import files into a database |
| `"sync-database"` | `sync-database.worker.ts` | Sync with origin database |
| `"replicate-database"` | `replicate-database.worker.ts` | Replicate to another database |
| `"verify-file"` | `verify.worker.ts` | Verify file integrity |
| `"check-file"` | `check.worker.ts` | Check if file is already imported |
| `"hash-file"` | `hash-file.worker.ts` | Compute file hash |
| `"upload-asset"` | `upload-asset.worker.ts` | Upload an asset |
| `"save-asset"` | `save-asset.worker.ts` | Save a single asset |
| `"save-assets-batch"` | `save-assets-batch.worker.ts` | Save a batch of assets |
| `"prefetch-database"` | `prefetch-database.worker.ts` | Prefetch thumbnails |
| `"create-database"` | `create-database.worker.ts` | Initialize a new database |
| `"get-database-summary"` | `get-database-summary.worker.ts` | Compute database statistics |
