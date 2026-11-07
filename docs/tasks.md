# Tasks

A background task is work that runs on a worker thread in the Zig backend, away from the thread that handles the page's messages. Anything slow (reading a database, hashing files, syncing, importing, waiting on a dialog or the phone's keychain) is a task, so the interface never waits on it.

The backend is Zig. In the Photosphere App the tasks run on the worker pool of [Ziggy](https://github.com/ashleydavis/ziggy)'s core, on every platform. In the Zig CLI they run on the CLI's own worker pool, built from Ziggy's workers. The frontend is TypeScript: it queues tasks and hears how they end, but runs none of them. See [Threads](threads.md) for the threads themselves.

## How it works

```
Frontend (TypeScript, in the web view)
  TaskQueue.addTask(type, data)                 packages/task-queue
    -> ZiggyQueueBackend.addTask                apps/photosphere-frontend/src/lib/ziggy-queue-backend.ts
    -> window.ziggy.addTask                     the add-task system message
Backend (Zig, in the core)
    -> main thread: worker pool queues it       an interactive task at the head, a background task at the end
    -> worker thread: runs the task's handler   packages-zig/node-api-zig/src/lib/<name>.worker.zig
    -> events and the result go to the main thread as JSON messages
    -> main thread sends task-event and task-completed to the page
Frontend
    -> ZiggyQueueBackend -> TaskQueue onTaskMessage / onTaskComplete / awaitTask
```

- A task's input is JSON data and its result is JSON. That is all that crosses between the threads, because the threads share no state.
- Every task belongs to a source, a string that groups tasks so they can be cancelled together. The frontend usually uses the database path or an import session id.
- The main thread sends the page `task-event` and `task-completed` for every task, including tasks the backend queued itself, so the interface sees all background work.

## The backend (Zig)

### Task handlers

Most tasks are written against Ziggy's task queue (`@import("ziggy").task_queue`) and live in `packages-zig/node-api-zig/src/lib`, one `<name>.worker.zig` per task type. Both the Photosphere App and the CLI run them. A handler takes the task's input as a JSON value and returns its result as one:

```zig
const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const open_storage = @import("open-storage.zig");
const ITaskContext = ziggy.task_queue.types.ITaskContext;
const Timers = ziggy.timers.Timers;

//
// Input data for the my-task task.
//
pub const IMyTaskData = struct {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: []const u8 = "",
};

//
// Task handler for my-task. Runs on a worker thread.
//
pub fn myTaskHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = timers;
    const data = std.json.parseFromValueLeaky(IMyTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return utils.errors.throwError("The my-task task data is not valid: databasePath must be a string", .{});
    };
    const opened = try open_storage.openStorage(allocator, io, data.databasePath, null, null, context.nativeCaller);
    _ = opened;

    // Check context.isCancelled(io, allocator) at the boundaries of long loops and stop early when it is true.
    // Send progress with context.sendEvent(io, allocator, event), where event is a JSON object with a "type".
    // context.uuidGenerator, context.timestampProvider and context.sessionId are there when the task needs them.

    return .null;
}
```

- The allocator is the task's own, an arena freed when the task ends. The Io and timers are the worker's. None of them are stored: each function that uses one is given it.
- An error the handler returns fails the task. Return a sentence the user can act on (`utils.errors.throwError`), never a bare error name, because `describe_error` passes that sentence to the page.
- `openStorage` opens a database's storage with its S3 credentials and encryption keys. `context.nativeCaller` lets it reach the phone's keychain. It is null on a desktop and in the CLI.
- A handler that runs ImageMagick or FFmpeg takes one more argument: the runner of the tools built into the program. It is listed in `tool_handlers` rather than `handlers`.

`task-handlers.zig` lists every one of these handlers by task type. `taskEntries` turns the list into Ziggy task types. The app adds them to the ones it declares (`apps/photosphere/core/src/app.zig`). The CLI's pool runs the same list.

### Tasks the app declares

A few tasks belong to the Photosphere App alone, such as the pickers, the vault and the keychain, the update and news checks and the mobile background passes. They are declared in `.tasks` of `apps/photosphere/core/src/app.zig` and written against Ziggy's task services rather than the task queue. Their handlers are in `packages-zig/photosphere-core/src/lib`. See [Tasks](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md) in Ziggy's guide for that form.

The background auto import, sync and prefetch passes are [keep-alive tasks](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#keep-alive-tasks), so a phone keeps running them while the app is in the background.

### Messages answered by a task

A message whose response waits on something slow (a picker, the vault, the phone's keychain) has its handler return `.task`, so a task gives the response. See [A message whose response is a task's result](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#a-message-whose-response-is-a-tasks-result) in Ziggy's guide. `pickers.zig` holds Photosphere's pickers.

### Tasks the main thread queues

The app queues work of its own from the main thread: the periodic and debounced sync, automatic import, the background passes and the update and news checks. A handler, timer or task end callback queues a task with `services.addTask(io, allocator, task_id, task_type, source, data_json, priority)` and cancels a source with `services.cancelTasks(io, allocator, source)`. See `main-state.zig` and `main-process.zig`.

The main thread hears how every task ends in `onTaskEnd` and every event a task sends in `onTaskEvent` (`main-process.zig`). That is how it applies what a task sends back, since a task never touches the main thread's state.

### Child tasks

A task can queue tasks of its own and wait for them, as `import-assets` does with `hash-file` and `upload-asset`. It makes a `TaskQueue` on its worker:

```zig
const queue = try TaskQueue.init(allocator, context.uuidGenerator, source);
defer queue.deinit(io, allocator);
_ = try queue.addTask(io, allocator, "hash-file", hashData, null, null);
try queue.awaitAllTasks(io, allocator, timers);
```

- `onTaskComplete`, `onTaskEvent`, `onAnyTaskEvent` and `awaitTask` work as they do in TypeScript.
- `context.maxConcurrentChildTasks` is how many children one task may have running at once, so an import never takes the whole pool.
- Ziggy's guide covers how the children are queued and what happens when every worker holds a parent waiting on its children: see [Child tasks](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#child-tasks) and [Code written against the task queue](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#code-written-against-the-task-queue).

### Priority and cancelling

Priority and cancelling work as Ziggy's guide describes (see [Tasks](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md)). Queue a task the user is waiting on as `interactive`, so it runs ahead of the sync and import work already queued. A handler that can be cancelled checks `context.isCancelled(io, allocator)` at the boundaries of its loops.

### The CLI

The CLI runs the same node-api task handlers on its own worker pool, `WorkerPoolBun` (`apps/cli-zig/src/lib/worker-pool.zig`). A command makes a `TaskQueue` and waits in `awaitTask` or `awaitAllTasks`. See [Threads](threads.md#the-zig-cli) for how the pool runs and times out its tasks.

## The frontend (TypeScript)

The page uses the same `TaskQueue` API (`packages/task-queue`) it always has. `apps/photosphere-frontend/src/app.tsx` installs `ZiggyQueueBackend` as the queue backend at startup. That backend forwards every call to the core over `window.ziggy`. The page runs no task itself.

### Queuing and consuming a task

```typescript
import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";

// The source string groups related tasks so they can be cancelled together.
const queue = new TaskQueue(new RandomUuidGenerator(), "my-source");

// Queue the task. Returns the task id.
const taskId = queue.addTask("my-task", { databasePath });

// A task the user is waiting on goes ahead of everything automatic import and syncing have already queued.
// The third argument is an explicit task id; pass undefined to have one minted.
const tapTaskId = queue.addTask("my-task", { databasePath }, undefined, TaskPriority.Interactive);

// Option A: await the result directly.
const result = await queue.awaitTask(taskId);
if (result?.status === TaskStatus.Succeeded) {
    const output = result.outputs as IMyTaskResult;
}

// Option B: subscribe to completion (handles all tasks in the queue).
queue.onTaskComplete<IMyTaskData, IMyTaskResult>((result) => {
    if (result.status === TaskStatus.Succeeded) {
        const output = result.outputs;
    }
});

// Always shut down the queue when done.
queue.shutdown();
```

The input and result types are TypeScript interfaces that mirror the Zig structs the handler reads and returns. Keep the field names the same on both sides, because the JSON is all that crosses.

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

### Streaming events from a task

For a long task that reports progress or streams batches, the handler sends an event with a `type`:

```zig
var event: std.json.ObjectMap = .empty;
try event.put(allocator, "type", .{ .string = "my-progress" });
try event.put(allocator, "percent", .{ .integer = 50 });
context.sendEvent(io, allocator, .{ .object = event });
```

The page listens for that type:

```typescript
queue.onTaskMessage<IMyProgressMessage>("my-progress", ({ message }) => {
    setProgress(message.percent);
});
```

`onTaskMessage` matches only events whose `type` field equals the given string. `onAnyTaskMessage` hears every event.

### Cancelling

`queue.shutdown()` cancels the tasks of the queue's source. `getQueueBackend().cancelTasks(source)` cancels the tasks of any source. Both reach `ZiggyQueueBackend.cancelTasks`, which sends the `cancel-tasks` main command rather than Ziggy's own cancel. The main command cancels through the core's queue backend, which also tells task queues in the backend (an import waiting on its children) that their source was cancelled, so they stop waiting for children that will never run.

## Surfacing a task as a job

A **job** is a named group of tasks that the user can see running and, where it makes sense, stop. The navbar shows what is running and the right sidebar lists each one with its elapsed time, what it is doing and a Cancel button.

Jobs live only in the frontend. No worker pool or worker keeps job state or decides when a job is over. The whole mechanism is two things: a tag in the task's input data and the handler reporting progress against it.

**Where the task is queued**, put an `IJobTag` in its input data, as `import-context.tsx` does:

```typescript
queue.addTask("import-assets", {
    ...importData,
    job: {
        id: sessionId,
        name: "Importing photos",
        cancelSource: sessionId,
    },
}, sessionId);
```

- `id` groups the tasks. Two tasks carrying the same id are one row. The row goes when the last of them completes. Include whatever tells two of the same kind of job apart, usually the database path.
- `name` is what the row is called.
- `cancelSource` is what the Cancel button passes to `cancelTasks()`, so it must be the `source` the task was queued with. **Leave it out when the job cannot be cancelled from the interface.** The row then renders without a Cancel button. A background sync leaves it out: the core's main thread queues it under a source the interface never learns. Syncing is switched off from Settings.

**In the handler**, read the tag into an optional field of the task's data (`job: ?IJobTag = null`) and report against it from wherever the handler already reports progress, as `sync-database.worker.zig` does:

```zig
const runStartedAt = context.timestampProvider.now(io);
...
try sendJobProgress(allocator, io, context, data.job, runStartedAt, try std.fmt.allocPrint(allocator, "{d} changes synced", .{changesSynced}));
```

- `sendJobProgress` (`ziggy.task_queue.job_progress`) sends no event when the tag is null, so a task queued without one never appears. Leave the tag off only for work no user would want to watch or stop, such as the hash and upload children an import queues for itself.
- `startedAt` is stamped by the handler and resent every time, so a job already running when a phone comes back to the foreground shows its real age rather than restarting from zero.
- There is no completion fraction to report. The interface shows a spinner rather than a bar. Most jobs here scan or stream and cannot know one. A job made of several tasks has no single answer. Say what the job is doing in the message instead.
- Report often enough that the row does not look stuck and no more often than the work moves.

**If the job can be cancelled**, the handler must check `context.isCancelled(io, allocator)` at the boundaries of its loops, or Cancel will remove the row while the work carries on.

Because the event and the completion of every task reach the page, this works the same for tasks the frontend queued and tasks the core's main thread queued, on every platform.

## Adding a new task type

1. Write the handler in `packages-zig/node-api-zig/src/lib/<name>.worker.zig`, with a struct for its input data and a comment on every field.
2. Add it to `handlers` in `packages-zig/node-api-zig/src/lib/task-handlers.zig` under its task type string, or to `tool_handlers` when it runs ImageMagick or FFmpeg. The type string must be unique. The app and the CLI both pick it up from there.
3. Report progress with `context.sendEvent`. For a job, report `job-progress` events through `sendJobProgress`, carrying the `IJobTag` found in the task's input data.
4. Queue it from the page with `TaskQueue.addTask`, from the main thread with `services.addTask`, or from a CLI command with `TaskQueue.addTask`.
5. Write the unit test under `packages-zig/node-api-zig/src/test` and a smoke test scenario when the task is reachable from a page.

A task that only the Photosphere App runs and that needs the task services (a native call, a message to the main thread) is declared in `apps/photosphere/core/src/app.zig` with its handler in `packages-zig/photosphere-core/src/lib` instead.

## Key files

| File | Purpose |
|------|---------|
| `packages-zig/node-api-zig/src/lib/task-handlers.zig` | Every task queue handler by task type and `taskEntries`, which makes them Ziggy task types |
| `packages-zig/node-api-zig/src/lib/*.worker.zig` | The task handlers |
| `packages-zig/node-api-zig/src/lib/open-storage.zig` | Opens a database's storage with its credentials and encryption |
| `apps/photosphere/core/src/app.zig` | The app's declaration: its own task types, keep-alive kinds and the node-api tasks added to them |
| `packages-zig/photosphere-core/src/lib/main-state.zig` | The main thread's timers that queue sync, import and the background passes |
| `packages-zig/photosphere-core/src/lib/main-process.zig` | `onTaskEnd`, `onTaskEvent` and the `cancel-tasks` main command |
| `apps/cli-zig/src/lib/worker-pool.zig` | The CLI's worker pool |
| [`task-queue/`](https://github.com/ashleydavis/ziggy/tree/HEAD/packages/ziggy/core/src/lib/task-queue) in Ziggy | The Zig `TaskQueue`, `ITaskContext`, `IJobTag` and `sendJobProgress` |
| [`worker-pool.zig`](https://github.com/ashleydavis/ziggy/blob/HEAD/packages/ziggy/core/src/lib/worker-pool.zig) and [`worker.zig`](https://github.com/ashleydavis/ziggy/blob/HEAD/packages/ziggy/core/src/lib/worker.zig) in Ziggy | The pool on the main thread and the worker threads |
| `apps/photosphere-frontend/src/lib/ziggy-queue-backend.ts` | The page's queue backend, which forwards to the core over `window.ziggy` |
| `packages/task-queue/src/lib/task-queue.ts` | The TypeScript `TaskQueue`: queue tasks, await results, subscribe to events |
| `packages/task-queue/src/lib/types.ts` | `ITaskResult`, `TaskStatus`, `TaskPriority`, `IJobTag` and the callbacks |
| `packages/user-interface/src/lib/jobs.ts` | Builds the job list from job progress and task completions |
| `packages/user-interface/src/context/jobs-context.tsx` | Provides the job list and `cancelJob` to the interface |
