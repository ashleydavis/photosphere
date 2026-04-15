# Test Plan: Task Queue Refactor

Tests to add following the task-queue architecture refactor (commit `a523b203`).

Check off each item as it is implemented.

---

## Summary of Changes

The commit is a large refactor of the task-queue architecture across the monorepo:

### `packages/task-queue`
- New `IQueueBackend` interface and `queue-backend.ts` module with `setQueueBackend` / `getQueueBackend` singleton helpers. All concrete backends (worker pools and IPC/WebSocket proxies) now implement this interface.
- New `TaskContext` class implementing `ITaskContext` — wraps `sendMessage`, `isCancelled`, `cancel`, and context values for a single executing task.
- New `WorkerQueueBackend` class — the `IQueueBackend` implementation used inside worker processes; dispatches child tasks to the main process via `postMessage` and fires callbacks when results are forwarded back.
- `TaskQueue` refactored: `addTask` no longer takes a `source` argument (source is fixed per-instance at construction time); `getStatus()` removed; `awaitTask(taskId)` added; cancellation now resolves all in-flight `awaitAllTasks` / `awaitTask` waiters immediately; `shutdown()` calls `backend.cancelTasks(source)` and unsubscribes all backend listeners.
- `mock-worker-backend.ts` renamed to `mock-worker-pool.ts`.

### `packages/api`
- New `hash-file.worker.ts` — split out from `upload-asset.worker.ts`; responsible only for computing / caching the SHA-256 hash and checking whether the asset already exists in the database.
- `import-assets.worker.ts` heavily refactored — now acts as an orchestrator: scans paths, queues `hash-file` tasks, deduplicates by content hash, queues `upload-asset` tasks for new files, and batches all database writes (Merkle tree + BSON) under a throttled write lock.
- `upload-asset.worker.ts` refactored — no longer writes to the database itself; instead returns a new `IUploadAssetResult` containing `IAssetDatabaseData` for the orchestrator to commit.
- `import.ts` updated to construct `TaskQueue` directly (replacing `ITaskQueueProvider`) and to use `awaitTask(taskId)`.

### App-level backends
- `apps/cli`: `task-queue-provider-bun.ts` removed; `worker-backend-bun.ts` renamed to `worker-pool-bun.ts`.
- `apps/desktop`: `worker-backend-electron-main.ts` renamed to `worker-pool-electron-main.ts`, significantly extended.
- `apps/desktop-frontend`: new `electron-renderer-queue-backend.ts` (IPC proxy implementing `IQueueBackend`); old `worker-backend-electron-renderer.ts` and `task-queue-provider-electron.ts` removed.
- `apps/dev-frontend`: new `websocket-queue-backend.ts` (WebSocket proxy implementing `IQueueBackend`); old `worker-backend-websocket.ts` and `task-queue-provider-websocket.ts` removed.
- `apps/dev-server`: `task-queue-provider-inline.ts` removed; `worker-backend-inline.ts` renamed to `worker-pool-inline.ts`.
- `packages/debug-server`: entirely deleted.

---

## 1. Add to existing test files

### `packages/task-queue/test/task-queue.test.ts`

- [x] `awaitTask(taskId)` resolves when the specific task completes
- [x] `awaitTask(taskId)` resolves immediately when the task ID is not tracked
- [x] Multiple `awaitTask(taskId)` callers on the same ID all resolve when the task completes
- [x] `awaitTask(taskId)` resolves immediately when `shutdown()` is called while waiting
- [x] `awaitAllTasks()` resolves immediately when `shutdown()` is called while waiting
- [x] `onTasksCancelled` fires `resolveAllWaiters`, unblocking both `awaitAllTasks` and `awaitTask` callers
- [x] Tasks from one `TaskQueue` instance (source A) do not trigger completion callbacks of another instance (source B) sharing the same backend
- [x] `addTask` with an explicit `taskId` argument passes that ID through to the backend

### `packages/api/src/test/lib/upload-asset.worker.test.ts`

- [x] When `contentType` starts with `video/`, `getVideoDetails` is called
- [x] When `contentType` starts with `image/`, `getImageDetails` is called
- [x] Returned `IAssetDatabaseData` includes `thumbPath`, `thumbHash`, `thumbLength`, `thumbLastModified` when a thumbnail is produced
- [x] Returned `IAssetDatabaseData` includes `displayPath`, `displayHash`, `displayLength`, `displayLastModified` when a display version is produced
- [x] `result.totalSize` equals the sum of asset + thumbnail + display byte lengths
- [x] In non-dry-run mode, `storage.writeStream` is called for the asset file, thumbnail, and display file

### `packages/api/src/test/lib/import-assets.worker.test.ts`

- [x] When `hash-file` reports a new file and `upload-asset` succeeds, an `import-success` message is sent
- [x] After a successful upload, `merkle-tree.addItem` and `metadataCollection.insertOne` are called with the correct data
- [x] `localHashCache.save()` is called after all tasks complete
- [x] When `acquireWriteLock` returns `false`, the handler retries until the lock is acquired (sleep is called)
- [x] `childQueue.shutdown()` is called in the `finally` block even when `scanPaths` throws

### `packages/api/src/test/lib/hash-file.worker.test.ts`

- [x] When `s3Config` is provided, storage is created with the S3 credentials
- [x] `dryRun: true` does not change the return value (hash-file is read-only regardless)

---

## 2. New test files to create

### `packages/task-queue/test/task-context.test.ts`

`TaskContext` is a new class with zero tests.

- [x] `isCancelled()` returns `false` initially
- [x] `cancel()` causes `isCancelled()` to return `true`
- [x] `sendMessage()` invokes the injected `sendMessageFn` with the correct argument
- [x] `uuidGenerator`, `timestampProvider`, `sessionId`, and `taskId` are exposed as provided by the constructor

### `packages/task-queue/test/queue-backend.test.ts`

`setQueueBackend` / `getQueueBackend` are new module-level functions with zero tests.

- [x] `getQueueBackend()` throws before `setQueueBackend()` is called
- [x] `getQueueBackend()` returns the backend set by `setQueueBackend()`
- [x] Calling `setQueueBackend()` a second time replaces the previously registered backend

### `packages/task-queue/test/worker-queue-backend.test.ts`

`WorkerQueueBackend` is a new class with zero tests.

- [x] `addTask()` calls `postMessage` with `{ type: "queue-task", taskId, taskType, data, source }`
- [x] `addTask()` fires `onTaskAdded` callbacks registered for the matching source
- [x] `onTaskAdded()` unsubscribe function removes only that callback
- [x] `onTaskComplete()` callback fires when `notifyTaskCompleted()` is called
- [x] `onTaskComplete()` unsubscribe function removes only that callback
- [x] `onTaskMessage()` callback fires only when the message type matches
- [x] `onTaskMessage()` unsubscribe function removes only that callback
- [x] `onAnyTaskMessage()` callback fires for all messages regardless of type
- [x] `onAnyTaskMessage()` unsubscribe function removes only that callback
- [x] `cancelTasks(source)` fires `onTasksCancelled` callbacks registered for that source
- [x] `onTasksCancelled()` unsubscribe function removes only that callback
- [x] `shutdown()` does not throw

### `apps/desktop-frontend/src/test/electron-renderer-queue-backend.test.ts`

`ElectronRendererQueueBackend` is a new file with no tests.

- [x] `addTask()` sends the correct IPC message via `ipcRenderer.send`
- [x] An incoming IPC `task-completed` message triggers `onTaskComplete` callbacks
- [x] An incoming IPC task message triggers `onTaskMessage` / `onAnyTaskMessage` callbacks
- [x] `cancelTasks()` sends the correct cancel IPC message
- [x] Unsubscribe functions remove only their registered callback

### `apps/dev-frontend/src/test/websocket-queue-backend.test.ts`

`WebSocketQueueBackend` is a new file with no tests.

- [x] `addTask()` sends the correct JSON over the WebSocket
- [x] An incoming `task-completed` WebSocket message triggers `onTaskComplete` callbacks
- [x] An incoming task-message WebSocket message triggers `onTaskMessage` / `onAnyTaskMessage` callbacks
- [x] `cancelTasks()` sends the correct cancel message over the WebSocket
- [x] Unsubscribe functions remove only their registered callback
