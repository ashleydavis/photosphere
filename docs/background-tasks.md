# Background Tasks

Background tasks run in a worker thread managed by the `task-queue` package. They handle CPU-heavy or I/O-bound work (database reads, file hashing, sync, import) without blocking the UI.

## How it works

- A `TaskQueue` queues tasks to a backend (`IQueueBackend`).
- The backend dispatches each task to a worker thread that calls the registered handler.
- Results and messages flow back to the caller via callbacks or `await`.

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
