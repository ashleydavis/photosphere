# Create Local Replica Feature

## Overview

Add a UI flow in the Electron desktop app that lets users create a partial local replica of a remote (S3 or other) database. The user picks a source database (already in their database list), chooses a local destination folder, and the app performs a partial replication — copying only metadata and thumbnails, with asset files fetched on demand from the origin. The newly created replica is registered in `databases.json` with its `origin` field pointing to the source, and is opened immediately after creation.

The core replication logic is being refactored into a task-worker architecture modelled on the `import-assets` / `upload-asset` pattern:
- A `replicate-database` orchestrator worker sets up storage, determines what to copy, and queues `copy-file` sub-tasks for each asset file.
- A `copy-file` worker copies one file from source to destination.
- Both the CLI and Electron dispatch the `"replicate-database"` task via a `TaskQueue` directly — no extra wrapper function is needed since `replicate()` already exists in the API package.

The Electron main process does no replication work — it dispatches to the `workerPool` and reacts to task completion events, exactly as it does for `sync-database`.

## Issues

## Steps

1. **Create `copy-file.worker.ts` sub-task handler**
   - File: `packages/api/src/lib/copy-file.worker.ts`
   - Define interface `ICopyFileData`:
     - `sourceDatabasePath: string`
     - `destDatabasePath: string`
     - `fileName: string` — relative path within the database (e.g. `assets/abc123.jpg`)
   - Define interface `ICopyFileResult`:
     - `fileName: string`
     - `hash: string` — hex-encoded hash of the copied file
     - `length: number`
     - `lastModified: string` — ISO date string
   - Implement `copyFileHandler(data, context)`:
     - Call `resolveStorageCredentials(data.sourceDatabasePath)` and `createStorage` for source
     - Call `createStorage(data.destDatabasePath)` for destination (plain FS, no credentials)
     - Stream the file from source to dest using `readStream` / `writeStream`
     - Compute and verify the hash of the copied file
     - Return `ICopyFileResult`

2. **Refactor `replicate.ts` to extract a file-list helper**
   - File: `packages/api/src/lib/replicate.ts`
   - Extract a new exported function `listFilesToReplicate(sourceAssetStorage, destAssetStorage, options)` that runs the merkle tree diff logic and returns the list of file names to copy. This lets the orchestrator worker determine what to copy without doing the copy itself.
   - Keep `replicate()` for direct callers that still need it (if any). Or remove it once the orchestrator replaces it entirely.

3. **Create `replicate-database.worker.ts` orchestrator**
   - File: `packages/api/src/lib/replicate-database.worker.ts`
   - Define interface `IReplicateDatabaseData`:
     - `sourceDatabasePath: string`
     - `destDatabasePath: string`
     - `partial: boolean`
   - Implement `replicateDatabaseHandler(data, context)` following the `importAssetsHandler` pattern:
     - Call `resolveStorageCredentials` and `createStorage` for both source and dest
     - Create `BsonDatabase` instances for both
     - If `partial`, copy the small set of known metadata files directly (README.md, `.db/files.dat`, BSON merkle trees) — no sub-tasks needed since these are few and small
     - If not `partial`, call `listFilesToReplicate(sourceAssetStorage, destAssetStorage)` to get the file list, then for each file queue a `copy-file` sub-task on a child `TaskQueue`
     - Listen for child task completions via `queue.onTaskComplete()`, update the dest merkle tree after each file is copied, and send progress messages via `context.sendMessage({ type: 'replicate-progress', copied, total })`
     - After all file copies finish, replicate BSON records (the existing `replicateBsonDatabase` logic)
     - Call `updateDatabaseConfig(destRawStorage, { origin: sourceDatabasePath, lastReplicatedAt: ... })`
     - Call `await queue.awaitAllTasks()` then `queue.shutdown()`

4. **Register both new task handlers**
   - File: `packages/api/src/lib/task-handlers.ts`
   - Import `copyFileHandler` from `./copy-file.worker`
   - Import `replicateDatabaseHandler` from `./replicate-database.worker`
   - Add `registerHandler("copy-file", copyFileHandler)`
   - Add `registerHandler("replicate-database", replicateDatabaseHandler)`

5. **Update CLI `replicate.ts` to use the task queue**
   - File: `apps/cli/src/cmd/replicate.ts`
   - Replace the direct `replicate(sourceAssetStorage, ...)` call with an inline `TaskQueue` dispatch:
     - Create `new TaskQueue(uuidGenerator, srcDir)`
     - Listen for `replicate-progress` messages via `queue.onAnyTaskMessage()` to drive the existing progress callback
     - Dispatch `"replicate-database"` task with `{ sourceDatabasePath: srcDir, destDatabasePath: destDir, partial: !!options.partial }`
     - Await the task, shut down the queue
   - Remove imports of storage objects and other items no longer needed directly in the CLI command

6. **Add IPC handler in Electron main process**
   - File: `apps/desktop/src/main.ts`
   - Define `IReplicateDatabaseInput` (imported from `electron-defs` — see step 7):
   - Add IPC handler `ipcMain.handle('replicate-database', ...)`:
     - Dispatch `"replicate-database"` to `workerPool` with `{ sourceDatabasePath: input.sourcePath, destDatabasePath: input.destPath, partial: true }`
     - Return the task ID immediately (same pattern as `startImportWithPaths`)
   - In `workerPool.onTaskComplete()`, handle `result.type === "replicate-database"`:
     - Read origin from dest DB config via `loadDatabaseConfig`
     - Add new `IDatabaseEntry` to `databases.json` using `addDatabaseEntry`
     - Send `'database-opened'` and a `'show-notification'` to the renderer

7. **Add `IReplicateDatabaseInput` and `replicateDatabase` to `IElectronAPI`**
   - File: `packages/electron-defs/src/lib/electron-api.ts`
   - Add interface `IReplicateDatabaseInput` with fields:
     - `sourcePath: string`, `destPath: string`, `name: string`, `description: string`
   - Add `replicateDatabase(input: IReplicateDatabaseInput): Promise<string>` (returns the task ID) to `IElectronAPI`

8. **Expose `replicateDatabase` in the preload script**
   - File: `apps/desktop/src/preload.ts`
   - Import `IReplicateDatabaseInput` from `electron-defs`
   - Add `replicateDatabase: (input) => ipcRenderer.invoke('replicate-database', input)`

9. **Add `IReplicateDatabaseInput` and `replicateDatabase` to `IPlatformContext`**
    - File: `packages/user-interface/src/context/platform-context.tsx`
    - Add `IReplicateDatabaseInput` interface (same four fields)
    - Add `replicateDatabase: (input: IReplicateDatabaseInput) => Promise<string>` to `IPlatformContext`

10. **Implement `replicateDatabase` in `PlatformProviderElectron`**
    - File: `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`
    - Add `replicateDatabase` callback delegating to `electronAPI.replicateDatabase`
    - Include it in `platformContext`

11. **Create `ReplicateDatabaseModal` component**
    - File: `packages/user-interface/src/components/replicate-database-modal.tsx`
    - Props: `open: boolean`, `onClose: () => void`
    - Form state interface `IReplicateDatabaseFormState`:
      - `sourcePath: string`, `destPath: string`, `name: string`, `description: string`
    - On mount, call `platform.getDatabases()` to populate a `<Select>` of source databases
    - "Browse" button calls `platform.pickFolder()` to fill `destPath`
    - On confirm: call `platform.replicateDatabase(...)`, subscribe to `onTaskComplete` to detect when the `replicate-database` task finishes, then call `onClose()`
    - Show a spinner with progress while replication is running
    - Disable the Create button when `sourcePath` or `destPath` is empty

12. **Add "Create local replica" button to `NoDatabaseLoaded`**
    - File: `packages/user-interface/src/components/no-database-loaded.tsx`
    - Import `ReplicateDatabaseModal`
    - Add `replicateModalOpen` state
    - Add a third button alongside "New database" and "Open database"
    - Render `<ReplicateDatabaseModal open={replicateModalOpen} onClose={() => setReplicateModalOpen(false)} />`

## Unit Tests

- `packages/api/src/test/copy-file-worker.test.ts`
  - Test `copyFileHandler` copies a file from source to dest and returns the correct hash
- `packages/api/src/test/replicate-database-worker.test.ts`
  - Test `replicateDatabaseHandler` in partial mode: verify metadata files are copied and `copy-file` sub-tasks are NOT queued
  - Test `replicateDatabaseHandler` in full mode: verify `copy-file` sub-tasks are queued for each differing file and the dest merkle tree is updated

## Smoke Tests

- Launch the Electron app
- Open the "No database loaded" screen
- Click "Create local replica"
- Select a remote S3 source database from the dropdown
- Pick a local destination folder, enter a name, click Create
- Verify: progress is shown, replica is created, app opens the new database, the entry in the databases list has `origin` populated pointing to the S3 source

## Verify

- `bun run compile` from repo root — no TypeScript errors
- `bun run test` from repo root — all tests pass
- `bun run test:cli` — CLI replicate smoke test passes

## Notes

- There is no separate `replicateDatabase()` API wrapper function — the existing `replicate()` function in `replicate.ts` provides all the direct-call logic the orchestrator needs internally, and both the CLI and Electron dispatch the `"replicate-database"` task via a `TaskQueue` directly.
- The orchestrator worker creates a child `TaskQueue` for `copy-file` sub-tasks. Because the worker process calls `setQueueBackend(workerBackend)` before running tasks, all child task dispatches are routed back through the main process to other worker utility processes — exactly as `hash-file` and `upload-asset` sub-tasks work in the import flow.
- In partial mode, only a handful of small metadata files are copied, so `copy-file` sub-tasks add overhead with no benefit. The orchestrator copies them inline.
- No work is done in the Electron main process during replication. The main process only dispatches the task to `workerPool` and reacts to the completion event.
- Only local (filesystem) destinations are supported — no S3 browser or S3 key selection for the replica destination.
- Source credentials (S3, encryption key) are resolved automatically via `resolveStorageCredentials` from `databases.json`, so no extra credential UI is needed.
