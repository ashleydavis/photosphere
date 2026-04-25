# Plan: Task Queue Refactor

## Goals

Note: Try to minimize changes to make it easier to diff.

1. `TaskQueue` is no longer a singleton — it is always a locally created object per operation
2. Real worker pools (`WorkerPoolBun`, `WorkerPoolElectronMain`, `WorkerPoolInline`) become true singletons created at app startup and terminated on shutdown
3. Shutting down a local `TaskQueue` cancels all in-flight tasks belonging to it (via `source` tag)
4. Remove `parentTaskId` / `awaitChildTasks` — per-queue isolation makes them redundant
5. Rename IPC/WebSocket proxy files to reflect their true nature (`ElectronQueueBackend`, `WebSocketQueueBackend`)

---

## Architecture Overview

```
  Main process (CLI / Desktop / Dev-server)
  ┌──────────────────────────────────────────┐
  │  workerPool  (singleton)                 │
  │  registered via setQueueBackend()        │
  │  ┌────────────────────────────────────┐  │
  │  │  WorkerPoolBun / WorkerPoolInline  │  │
  │  │  WorkerPoolElectronMain            │  │
  │  └────────────────────────────────────┘  │
  │                                          │
  │  per-operation:                          │
  │  ┌────────────────────────────────────┐  │
  │  │  TaskQueue  source="db/path"       │  │
  │  │  numTasksInFlight: number          │  │
  │  └────────────────────────────────────┘  │
  └──────────────────────────────────────────┘

  Frontend (Electron renderer / Dev-frontend)
  ┌──────────────────────────────────────────┐
  │  backend  (singleton per app / connection)│
  │  registered via setQueueBackend()        │
  │  ┌────────────────────────────────────┐  │
  │  │  ElectronQueueBackend              │  │
  │  │  WebSocketQueueBackend             │  │
  │  └────────────────────────────────────┘  │
  │                                          │
  │  per-operation:                          │
  │  ┌────────────────────────────────────┐  │
  │  │  TaskQueue  source="db/path"       │  │
  │  │  numTasksInFlight: number          │  │
  │  └────────────────────────────────────┘  │
  └──────────────────────────────────────────┘
```

---

## Interface / Class Hierarchy

```
IQueueBackend  (new — packages/task-queue/src/lib/queue-backend.ts)
│   addTask(type, data, source, taskId?): string
│   onTaskAdded(source, callback): UnsubscribeFn
│   onTaskComplete(callback): UnsubscribeFn
│   onTaskMessage(type, callback): UnsubscribeFn
│   onAnyTaskMessage(callback): UnsubscribeFn
│   cancelTasks(source): void
│   shutdown(): void

Module-level helpers (queue-backend.ts):
│   setQueueBackend(backend: IQueueBackend): void
│   getQueueBackend(): IQueueBackend

IWorkerPool  (worker-pool.ts — worker-specific extras only)
│   isIdle(): boolean
│   getStatus(): { peakWorkers: number }

WorkerPoolBun          implements IQueueBackend, IWorkerPool  (apps/cli)
WorkerPoolElectronMain implements IQueueBackend, IWorkerPool  (apps/desktop)
WorkerPoolInline       implements IQueueBackend, IWorkerPool  (apps/dev-server)

ElectronQueueBackend   implements IQueueBackend               (apps/desktop-frontend)
WebSocketQueueBackend  implements IQueueBackend               (apps/dev-frontend)

TaskQueue  (packages/task-queue — per-source tracker)
    constructor(uuidGenerator, timestampProvider, source: string)
                                          ← calls getQueueBackend() internally
    addTask(type, data, taskId?): string  ← calls backend.addTask with this.source
    awaitAllTasks(): Promise<void>
    awaitTask(taskId): Promise<void>
    onTaskComplete(callback): UnsubscribeFn
    onTaskMessage(type, callback): UnsubscribeFn
    onAnyTaskMessage(callback): UnsubscribeFn
    getStatus(): IQueueStatus
    shutdown()   ← calls backend.cancelTasks(this.source)

ITaskContext  (used inside task handlers)
    uuidGenerator, timestampProvider, sessionId, taskId
    sendMessage(msg): void
    isCancelled(): boolean
```

> **Note on `TaskQueue` design:** `TaskQueue` is a pure per-source tracker with no pending list
> or dispatch loop. On construction it calls `getQueueBackend()` and registers
> `backend.onTaskAdded(this.source, ...)` and `backend.onTaskComplete(...)` to maintain
> `numTasksInFlight`. All scheduling lives in the backend.
> Task handlers that need to queue work create a `TaskQueue` directly — `ITaskContext` has no
> queue methods. In worker processes, `setQueueBackend` is called during worker init with a
> worker-side proxy so `new TaskQueue(...)` works the same way everywhere.

> **Note on `IWorkerPool` vs `IQueueBackend`:** Two separate, unrelated interfaces. `IWorkerPool`
> declares only worker-specific extras (`isIdle`, `getStatus`). Real worker pools implement both
> independently via TypeScript structural typing. Frontend backends implement only `IQueueBackend`.

> **Note on singletons:** All `IQueueBackend` implementations are singletons. Each process calls
> `setQueueBackend(...)` once at startup. Only `TaskQueue` is created per-operation.

---

## Step-by-step Changes

### Step 1: Create `packages/task-queue/src/lib/queue-backend.ts`

New file defining `IQueueBackend` and the module-level `setQueueBackend` / `getQueueBackend`
helpers. Move shared callback types here (`WorkerTaskCompletionCallback`, `IMessageCallbackEntry`,
`TaskMessageCallback`, `UnsubscribeFn`, `ITaskMessageData`).
Export all from `packages/task-queue/src/index.ts`.

### Step 2: Update `IWorkerPool` in `packages/task-queue/src/lib/worker-pool.ts`

- Declare only worker-specific extras: `isIdle(): boolean` and `getStatus(): { peakWorkers: number }`
- No shared methods with `IQueueBackend` — concrete classes implement both interfaces independently

### Step 3: Rename proxy files

| Old file | New file |
|----------|----------|
| `apps/desktop-frontend/src/lib/worker-pool-electron-renderer.ts` | `electron-queue-backend.ts` |
| `apps/dev-frontend/src/lib/worker-pool-websocket.ts` | `websocket-queue-backend.ts` |

Class renames: `WorkerPoolElectronRenderer` → `ElectronQueueBackend`, `WorkerPoolWebSocket` → `WebSocketQueueBackend`.
Both implement `IQueueBackend` instead of `IWorkerPool`.
Update provider files and all imports.

### Step 4: Remove `parentTaskId` from types

In `packages/task-queue/src/lib/worker-pool.ts`:
- Remove `parentTaskId?: string` from `ITask`
- Remove `parentTaskId?: string` from `ITaskResult`
- Keep `taskType: string` and `inputs: any` on `ITaskResult` (used by `import-assets.worker.ts`)

### Step 5: Refactor `TaskQueue` (`packages/task-queue/src/lib/task-queue.ts`)

- Constructor: `(uuidGenerator, timestampProvider, source: string)` — calls `getQueueBackend()`
- Register `backend.onTaskAdded(source, ...)` to increment `numTasksInFlight`
- Register `backend.onTaskComplete(...)` to decrement `numTasksInFlight` (filtered to `this.source`)
- **`addTask(type, data, taskId?)`**: calls `backend.addTask(type, data, this.source, taskId)`
- **`awaitAllTasks()`**: resolves immediately if `numTasksInFlight <= 0`, otherwise waits
- **`awaitTask(taskId)`**: resolves when that task ID completes
- **`shutdown()`**: call `this.backend.cancelTasks(this.source)` then clear state
- Remove pending list and dispatch loop — no longer needed
- Remove `ITaskQueueProvider` from this file and from `index.ts`
- Update `ITaskQueue` interface to match

### Step 6: Update `ITaskContext` (`packages/task-queue/src/lib/types.ts`)

- Remove `addTask`, `awaitChildTasks` — task handlers create a `TaskQueue` directly if needed
- Keep `uuidGenerator`, `timestampProvider`, `sessionId`, `taskId`, `sendMessage`, `isCancelled`

### Step 7: Update `TaskContext` (`packages/task-queue/src/lib/task-context.ts`)

- Remove `addTaskFn`, `addTask`, `completionCallbacks`, `notifyChildTaskComplete`

### Step 8: Update worker pool files to implement `IQueueBackend`

**`apps/cli/src/lib/worker-pool-bun.ts`** and **`apps/desktop/src/lib/worker-pool-electron-main.ts`:**
- Add `addTask(type, data, source, taskId?)` — schedules task internally, fires `onTaskAdded`
- Add `onTaskAdded(source, callback)` — notifies `TaskQueue` instances tracking that source
- Remove `AddTaskCallback` constructor parameter — `"queue-task"` messages from workers call `this.addTask(...)`
- Remove `IWorkerQueueTaskMessage.parentTaskId`
- Remove `broadcastTaskCompleted`
- Move pending list and dispatch loop into these pool implementations

**`apps/dev-server/src/lib/worker-pool-inline.ts`:**
- Add `addTask(type, data, source, taskId?)` — fires `onTaskAdded`, executes inline
- Add `onTaskAdded(source, callback)`
- Remove `AddTaskCallback` constructor parameter
- Remove `parentTaskId` from task context construction

### Step 9: Call `setQueueBackend` at startup in each process

- `apps/cli/src/lib/init-cmd.ts`: call `setQueueBackend(workerPool)` after creating `WorkerPoolBun`
- `apps/desktop/src/lib/worker-pool-electron-main.ts`: call `setQueueBackend(...)` at module level; register `workerPool.shutdown()` on Electron `app.on('quit', ...)`
- `apps/dev-server/src/index.ts`: call `setQueueBackend(workerPool)` after creating `WorkerPoolInline`; register `workerPool.shutdown()` on process `SIGINT` / `SIGTERM`
- `apps/desktop-frontend`: call `setQueueBackend(new ElectronQueueBackend(...))` at startup
- `apps/dev-frontend`: call `setQueueBackend(new WebSocketQueueBackend(...))` on connection
- Worker processes (`apps/desktop/src/worker.ts` etc.): call `setQueueBackend(workerSideProxy)` during init

### Step 10: Update `apps/desktop/src/worker.ts`

- Remove `parentTaskId` from the `IWorkerQueueTaskMessage` it posts
- Call `setQueueBackend(workerSideProxy)` during worker init so task handlers can use `new TaskQueue(...)`

### Step 11: Update API package

**`packages/api/src/lib/import-assets.worker.ts`:**
- Remove `parentTaskId` from `context.addTask(...)` calls — replace with `new TaskQueue(...)` directly
- Remove `result.parentTaskId !== context.taskId` filter

**`packages/api/src/lib/import.ts`**, **`check.ts`**, **`verify.ts`**:
- Replace `taskQueueProvider: ITaskQueueProvider` — create `new TaskQueue(uuidGenerator, timestampProvider, source)` locally
- Use `awaitAllTasks()` + `queue.shutdown()`

**`packages/api/src/lib/load-assets.ts`:** Update `addTask` calls — use a local `TaskQueue`.

### Step 12: Replace `ITaskQueueProvider` at the app level

**`apps/cli/src/lib/init-cmd.ts`:**
- `ICommandContext.taskQueueProvider` → `workerPool: IWorkerPool`
- Create `WorkerPoolBun` in `initContext`; call `setQueueBackend(workerPool)`; register `workerPool.shutdown()` on termination

**`apps/cli/src/cmd/add.ts`, `check.ts`, `verify.ts`:** Pass `workerPool` to API functions (for `IWorkerPool` extras only).

**`apps/dev-server/src/index.ts`:** Module-level `WorkerPoolInline` singleton; call `setQueueBackend`; create `TaskQueue` per-operation.

**Delete:**
- `apps/dev-server/src/lib/task-queue-provider-inline.ts`
- `apps/cli/src/lib/task-queue-provider-bun.ts`

**Frontend provider files** (`task-queue-provider-electron.ts`, `task-queue-provider-websocket.ts`):
Update to use renamed backend classes and call `setQueueBackend`; keep structure.

### Step 13: Update tests

- `packages/task-queue/test/mock-worker-pool.ts`: remove `awaitChildTasks`, remove `parentTaskId`, add `addTask` / `onTaskAdded`
- `packages/task-queue/test/task-queue.test.ts`: call `setQueueBackend(mock)` in setup; remove `source` from `addTask`
- `packages/api/src/test/lib/import-assets.worker.test.ts`: remove `awaitChildTasks`, remove `parentTaskId` assertions
- `packages/api/src/test/lib/upload-asset.worker.test.ts`, `hash-file.worker.test.ts`: remove `awaitChildTasks`

---

## Global Singleton Summary

```
apps/cli
  └── WorkerPoolBun          (created in initContext, registered via setQueueBackend)

apps/desktop (main process)
  └── WorkerPoolElectronMain (module-level, registered via setQueueBackend)

apps/dev-server
  └── WorkerPoolInline       (module-level, registered via setQueueBackend)

apps/desktop-frontend
  └── ElectronQueueBackend   (one per app lifetime, registered via setQueueBackend)

apps/dev-frontend
  └── WebSocketQueueBackend  (one per WebSocket connection, registered via setQueueBackend)

worker processes (Bun threads / Electron utility processes)
  └── worker-side proxy      (registered via setQueueBackend during worker init)
```

