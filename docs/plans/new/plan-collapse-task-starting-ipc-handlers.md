# Collapse Renderer-Triggered Task-Starting IPC Handlers Onto `TaskQueue`

## Overview

The desktop main process currently exposes a dedicated `ipcMain.handle('<task-name>', ...)` for every renderer-initiated background task. Each one duplicates the same shape: receive a request, optionally show a native picker, call `workerPool.addTask(...)`, occasionally `await` completion via a *second* `TaskQueue` instance built only for awaiting. The renderer also needs a matching method on `IElectronAPI` / `IPlatformContext` / both providers — five or six file edits per task type, plus dedicated request/response types.

The renderer already has everything it needs to drive these flows itself:
- An `ElectronRendererQueueBackend` is registered as the process-level queue backend at app startup ([apps/desktop-frontend/src/app.tsx:38-39](apps/desktop-frontend/src/app.tsx#L38-L39)).
- The renderer can instantiate `new TaskQueue(new RandomUuidGenerator(), source)` directly, and the queue routes `addTask`/`onTaskComplete`/`onTaskMessage` through the IPC backend. The pattern is already in use at [packages/user-interface/src/context/asset-database-source.tsx:518](packages/user-interface/src/context/asset-database-source.tsx#L518).
- The replicate-database flow was just refactored to this pattern: the dialog creates its own `TaskQueue`, calls `queue.addTask("replicate-database", data)`, subscribes via `queue.onTaskMessage`/`queue.onTaskComplete`, and `shutdown()`s the queue on unmount. No platform-context wrapper, no new IPC, no manual taskId filtering.

This plan extends that pattern to every remaining renderer-triggered task handler.

The non-negotiable constraints are:
- **Native file pickers must stay in the main process** (they need access to `dialog`). They become small focused IPCs (`pick-folder`, `pick-save-location`) — *not* task-starting handlers.
- **Task-completion side effects** (notifications, `databases.json` updates) currently live in main's `onTaskComplete` branches inside [initWorkers()](apps/desktop/src/main.ts#L741). They stay where they are — they are reactions to *all* task completions from any source, not IPC handlers, and they keep working unchanged.
- **CRUD-style IPC handlers** (`vault-*`, `add-database`, `get-config`, etc.) are out of scope. They are not tasks.

End state: the only IPC channels the renderer uses to interact with the worker pool are the generic ones that `ElectronRendererQueueBackend` already speaks (`add-task`, `cancel-tasks`, `task-completed`, `task-message`). Every task-starting handler in `main.ts` is deleted. The renderer creates its own `TaskQueue` per flow.

## Issues
<!-- populated later by plan:check -->

## Inventory

The following dedicated task-starting handlers exist in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) today and will be collapsed.

| # | IPC channel | Picker (if any) | Task queued | Notes |
|---|---|---|---|---|
| 1 | `create-database` ([line 285](apps/desktop/src/main.ts#L285)) | `showDirectoryPicker('Create Database', ['createDirectory'])` | `create-database` | Calls `createNewDatabase()` which creates a **separate** `TaskQueue` just to `await` the task ([main.ts:1151-1156](apps/desktop/src/main.ts#L1151-L1156)) |
| 2 | `create-database-at-path` ([line 345](apps/desktop/src/main.ts#L345)) | none | `create-database` | Calls `createDatabaseAtPathDirect()` which also creates a separate `TaskQueue` just to await ([main.ts:331-335](apps/desktop/src/main.ts#L331-L335)) |
| 3 | `save-asset` ([line 550](apps/desktop/src/main.ts#L550)) | `dialog.showSaveDialog` (defaults to `lastDownloadFolder`) | `save-asset` | |
| 4 | `save-assets` ([line 574](apps/desktop/src/main.ts#L574)) | `dialog.showOpenDialog` (folder, defaults to `lastDownloadFolder`) | `save-assets-batch` | |
| 5 | `import-assets` ([line 602](apps/desktop/src/main.ts#L602)) | `showDirectoryPicker('Import Assets')` when `paths` is empty | `import-assets` | Also called from the File menu ([main.ts:1309](apps/desktop/src/main.ts#L1309)) and the test control server ([main.ts:184-191](apps/desktop/src/main.ts#L184-L191)) |
| ✓ | `replicate-database` | none | `replicate-database` | **Already done** — dialog uses `new TaskQueue(...)` directly |

Out of scope (kept dedicated for the stated reason):
- `open-file` ([main.ts:284](apps/desktop/src/main.ts#L284)) — opens a folder picker and sends `database-opened`, no task involved. Could fold into `pickFolder` + a renderer-side `notifyDatabaseOpened`, but that has nothing to do with the task-handler duplication this plan targets. Skip.
- `cancel-tasks` ([main.ts:272](apps/desktop/src/main.ts#L272)) — already generic.
- `add-task` ([main.ts:262](apps/desktop/src/main.ts#L262)) — already generic; this is what `ElectronRendererQueueBackend` actually sends.

## Steps

### 1. Expose the native save-dialog as a picker IPC

`save-asset` is the only handler that uses `dialog.showSaveDialog`. To collapse it we need that picker accessible from the renderer.

**1a. Add the IPC handler in main.**
- File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Add next to the existing `pick-folder` handler:
  ```ts
  ipcMain.handle('pick-save-location', logExceptions(async (_event, defaultFilename: string) => {
      const config = await loadDesktopConfig();
      const defaultPath = config.lastDownloadFolder
          ? join(config.lastDownloadFolder, defaultFilename)
          : defaultFilename;
      const result = await dialog.showSaveDialog(mainWindow!, { defaultPath });
      if (result.canceled || !result.filePath) {
          return undefined;
      }
      await updateLastDownloadFolder(dirname(result.filePath));
      return result.filePath;
  }, 'Error picking save location'));
  ```
- The `updateLastDownloadFolder` side effect moves from inside `save-asset` into the picker — it conceptually belongs to the picker (user just confirmed a folder).

**1b. Expose through preload, electron-defs, and platform context.**
- [preload.ts](apps/desktop/src/preload.ts): `pickSaveLocation: (defaultFilename) => ipcRenderer.invoke('pick-save-location', defaultFilename)`.
- [electron-api.ts](packages/electron-defs/src/lib/electron-api.ts): add `pickSaveLocation: (defaultFilename: string) => Promise<string | undefined>` to `IElectronAPI`.
- [platform-context.tsx](packages/user-interface/src/context/platform-context.tsx): add `pickSaveLocation: (defaultFilename: string) => Promise<string | undefined>`.
- [platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): wrap `electronAPI.pickSaveLocation`.
- [platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): stub returning `undefined`.

### 2. Generalise `pickFolder` for download-folder defaults

`save-assets` uses a folder picker defaulting to `lastDownloadFolder` and persisting the choice. The existing `pickFolder` defaults to `lastFolder` (different desktop-config key) and persists nothing.

**Approach:** extend `pickFolder` to accept an optional argument bundle:

```ts
export interface IPickFolderOptions {
    // Window title for the picker dialog.
    title?: string;

    // Default folder source — 'lastFolder' (default) or 'lastDownloadFolder'.
    defaultFrom?: 'lastFolder' | 'lastDownloadFolder';

    // When the user confirms, persist the chosen folder back to this config key.
    persistTo?: 'lastFolder' | 'lastDownloadFolder';

    // Whether to expose the "New Folder" button in the native dialog.
    createDirectory?: boolean;
}
```

Calling `pickFolder()` with no args keeps current behaviour. Save-assets calls `pickFolder({ title: 'Choose folder to save assets', defaultFrom: 'lastDownloadFolder', persistTo: 'lastDownloadFolder', createDirectory: true })`.

Wire through preload, electron-defs, platform-context, and both providers (Step 1b shape).

### 3. Collapse `save-asset`

**3a. Update the renderer.**
- The `save-asset` call site is `platform.downloadAsset(...)` ([platform-provider-electron.tsx:451-453](apps/desktop-frontend/src/lib/platform-provider-electron.tsx#L451-L453)). Today it forwards to `electronAPI.saveAsset`.
- Replace `downloadAsset` with:
  ```ts
  const downloadAsset = useCallback(async (assetId, assetType, filename, _contentType, databasePath) => {
      const destPath = await electronAPI.pickSaveLocation(filename);
      if (!destPath) return;

      const queue = new TaskQueue(new RandomUuidGenerator(), databasePath);
      queue.onTaskComplete(() => queue.shutdown());
      queue.addTask("save-asset", { assetId, assetType, destPath, databasePath });
  }, [electronAPI]);
  ```
- The notification is fired by the existing `onTaskComplete` branch in main ([main.ts:754-771](apps/desktop/src/main.ts#L754-L771)). The renderer doesn't need to subscribe.
- Shutdown the queue on completion to release subscriptions.

**3b. Delete the obsolete handler and exports.**
- Delete `ipcMain.handle('save-asset', ...)` in [main.ts:550](apps/desktop/src/main.ts#L550).
- Delete `saveAsset` from `electronAPI` in [preload.ts](apps/desktop/src/preload.ts) and from `IElectronAPI` in [electron-api.ts](packages/electron-defs/src/lib/electron-api.ts).
- Keep the `save-asset` branch in `onTaskComplete` — it shows the notification and reads `result.inputs.destPath` regardless of who queued the task.

### 4. Collapse `save-assets`

**4a. Update the renderer.**
- Replace `downloadAssets` ([platform-provider-electron.tsx:455-462](apps/desktop-frontend/src/lib/platform-provider-electron.tsx#L455-L462)):
  ```ts
  const downloadAssets = useCallback(async (assets, databasePath) => {
      const folderPath = await electronAPI.pickFolder({
          title: 'Choose folder to save assets',
          defaultFrom: 'lastDownloadFolder',
          persistTo: 'lastDownloadFolder',
          createDirectory: true,
      });
      if (!folderPath) return;

      const saveItems: ISaveAssetItem[] = assets.map(asset => ({
          assetId: asset.assetId,
          assetType: asset.assetType,
          filename: asset.filename,
      }));

      const queue = new TaskQueue(new RandomUuidGenerator(), databasePath);
      queue.onTaskComplete(() => queue.shutdown());
      queue.addTask("save-assets-batch", { assets: saveItems, folderPath, databasePath });
  }, [electronAPI]);
  ```

**4b. Delete the handler.**
- Delete `ipcMain.handle('save-assets', ...)` in [main.ts:574](apps/desktop/src/main.ts#L574), the preload bridge, and the `IElectronAPI.saveAssets` declaration.
- Keep the `save-assets-batch` branch in `onTaskComplete` (it shows the success/partial/failure notification).

### 5. Collapse `import-assets`

This one is more involved because `import-assets` is called from three places: the renderer (drag-and-drop or button), the File menu (main-side), and the test control server (main-side).

**5a. Update the renderer.**
- File: [platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx).
- Today `platform.importAssets(paths?)` calls `electronAPI.importAssets(paths)` and returns `{ importAssetsTaskId, sessionId }`.
- Replace with:
  ```ts
  const importAssets = useCallback(async (paths?: string[]): Promise<IImportSession | undefined> => {
      if (!currentDatabasePath) return undefined;

      let resolvedPaths = paths;
      if (!resolvedPaths || resolvedPaths.length === 0) {
          const folder = await electronAPI.pickFolder({ title: 'Import Assets' });
          if (!folder) return undefined;
          resolvedPaths = [folder];
      }

      const sessionId = new RandomUuidGenerator().generate();
      const queue = new TaskQueue(new RandomUuidGenerator(), sessionId);
      queue.onTaskComplete(() => queue.shutdown());
      const importAssetsTaskId = queue.addTask('import-assets', {
          paths: resolvedPaths,
          storageDescriptor: { databasePath: currentDatabasePath },
          sessionId,
          dryRun: false,
      });
      return { importAssetsTaskId, sessionId };
  }, [electronAPI, currentDatabasePath]);
  ```
- The renderer needs `currentDatabasePath`. It already tracks the open database for asset queries; plumb that existing source rather than adding a new IPC.

**5b. Route the menu-initiated import through the renderer.**
- The File menu currently calls `selectAndImportAssets()` directly inside main ([main.ts:1309](apps/desktop/src/main.ts#L1309)). After this refactor that path no longer works.
- Change the menu click to `mainWindow.webContents.send('menu-action', 'import-assets')`.
- In the renderer's existing menu-action subscriber, handle `'import-assets'` by calling `platform.importAssets()` (no args → triggers the picker).

**5c. The test control server.**
- [test-control-server.ts](apps/desktop/src/lib/test-control-server.ts) calls `importAssets` via a callback that today queues `add-paths` directly via `workerPool.addTask` ([main.ts:184-191](apps/desktop/src/main.ts#L184-L191)). That code runs in main and bypasses IPC — leave it alone. It does not need this refactor.

**5d. Delete the handler and helpers.**
- Delete `ipcMain.handle('import-assets', ...)`, `selectAndImportAssets`, and `startImportWithPaths` from main.
- Delete `importAssets` from `electronAPI` (preload + electron-defs).
- Keep the `import-assets` and `add-paths` branches in `onTaskComplete`.

### 6. Collapse `create-database` and `create-database-at-path`

The interesting refactor — both today create a **separate `TaskQueue` instance in main** just so the caller can `await` task completion ([main.ts:331-335](apps/desktop/src/main.ts#L331-L335) and [main.ts:1151-1156](apps/desktop/src/main.ts#L1151-L1156)). That's a duplicate queue per call, only used to bridge the main worker pool's callback API to an awaitable. The renderer-side `TaskQueue` solves this naturally — `queue.awaitTask(taskId)` is already there.

**6a. Update the renderer — "create at known path" (databases page, test control).**
- The Databases page calls `platform.createDatabaseAtPath(databasePath)` after the user enters a path. Replace the implementation:
  ```ts
  const createDatabaseAtPath = useCallback(async (databasePath: string) => {
      const queue = new TaskQueue(new RandomUuidGenerator(), databasePath);
      try {
          const taskId = queue.addTask('create-database', { databasePath });
          await queue.awaitTask(taskId);
      }
      finally {
          queue.shutdown();
      }
      await platform.notifyDatabaseOpened(databasePath);
  }, []);
  ```
- The previous main-side `mainWindow.webContents.send('database-opened', databasePath)` becomes the renderer's own `platform.notifyDatabaseOpened` call — same downstream effect, no IPC round-trip.

**6b. Update the renderer — "create with picker" (File menu).**
- Today `electronAPI.createDatabase()` shows a folder picker, creates the database, sends `database-opened`. Replace with:
  ```ts
  const createDatabase = useCallback(async () => {
      const databasePath = await electronAPI.pickFolder({
          title: 'Create Database',
          createDirectory: true,
      });
      if (!databasePath) return;
      await createDatabaseAtPath(databasePath);
  }, [electronAPI, createDatabaseAtPath]);
  ```

**6c. Delete the handlers and helpers.**
- Delete `ipcMain.handle('create-database', ...)`, `createNewDatabase()`, `ipcMain.handle('create-database-at-path', ...)`, and `createDatabaseAtPathDirect()` from main.
- Delete `createDatabase` and `createDatabaseAtPath` from `electronAPI` (preload + electron-defs). `platform.createDatabase` and `platform.createDatabaseAtPath` stay on `IPlatformContext` — they are the cross-platform abstraction, just no longer go through dedicated IPCs.
- Update the test control server: its `createDatabaseAtPath` callback ([main.ts:177](apps/desktop/src/main.ts#L177)) currently uses `createDatabaseAtPathDirect`. Switch it to use `workerPool.addTask('create-database', { databasePath }, databasePath)` plus a `workerPool.awaitTask(...)` call. If `awaitTask` is not on the main `IQueueBackend` today, either add a thin wrapper or have the test control server briefly subscribe to `onTaskComplete` and resolve on match. The test control server runs in main so it can use either approach.

### 7. Add `data: any` typing consistency check

The `electron-renderer-queue-backend.ts` already accepts `data: any` (`addTask(type: string, data: any, source: string, taskId?: string): string`). The refactored renderer call sites pass typed `data` objects (e.g. `IReplicateDatabaseData`); TypeScript implicit-any-checks pass them through `addTask` cleanly. No type-system work needed.

### 8. Document the pattern in CLAUDE.md

Add a short rule:

> When the renderer needs to start a background task, create a `TaskQueue` directly with `new TaskQueue(new RandomUuidGenerator(), source)` and use `queue.addTask(...)`. Do not add a dedicated `ipcMain.handle('<task-name>', ...)` in main, and do not add a wrapper method on `IPlatformContext` for individual task types. Native pickers (folder, save-dialog) stay as small focused IPCs. Task-completion side effects (notifications, `databases.json` updates) live in main's `onTaskComplete` branches and stay there.

This prevents new dedicated handlers from creeping back in.

## Unit Tests

- `ElectronRendererQueueBackend` is already covered by existing tests ([apps/desktop-frontend/src/test/electron-renderer-queue-backend.test.ts](apps/desktop-frontend/src/test/electron-renderer-queue-backend.test.ts)). No changes needed there — the refactored renderer code uses the existing backend through `TaskQueue`.
- Add a small renderer-side test for each refactored flow that mocks the queue backend and asserts: `pickFolder`/`pickSaveLocation` is called, then `addTask` is called with the right task type and data shape. One test per flow (`downloadAsset`, `downloadAssets`, `importAssets`, `createDatabaseAtPath`).
- Delete any main-process tests that mock `ipcMain.handle('save-asset', ...)`, `'create-database', ...`, etc. (grep `ipcMain` under [apps/desktop/src/test](apps/desktop/src/test) first).
- `TaskQueue` itself is covered by its own existing tests — those keep passing.

## Smoke Tests

The existing smoke tests already cover the user-visible flows:
- [10-view-database](apps/desktop/smoke-tests/10-view-database/test.sh) — open/view.
- [17-replicate-database](apps/desktop/smoke-tests/17-replicate-database/test.sh) — already on the new pattern; regression check.
- Existing import-assets, save-asset, save-assets, and create-database smoke tests — re-run after each step.

Run order:
1. After Steps 1+2 (pickers exposed, no behaviour change yet): all existing smoke tests pass.
2. After Steps 3, 4, 5, 6 individually: re-run the corresponding feature's smoke test and the full `bun run test:electron` suite.

If Step 5b changes the menu-import path, retest the menu-initiated import explicitly — that path is easy to break.

## Verify

1. `bun run compile` from repo root.
2. `bun run test` from repo root.
3. `bun run test:cli` from repo root.
4. `bun run test:electron` from repo root.
5. `grep -c "^ipcMain.handle" apps/desktop/src/main.ts` should drop by **5** (steps 3, 4, 5, 6 collapse 5 handlers: save-asset, save-assets, import-assets, create-database, create-database-at-path) and add **1** (pick-save-location). Net: **-4**.
6. `grep -c "new TaskQueue" packages/user-interface/src apps/desktop-frontend/src` should go *up* — the renderer is taking on the orchestration role that main used to play.

## Human Verification

1. **Create database (with picker)**: File → New Database → pick a fresh folder → confirm the gallery opens.
2. **Create database (at known path)**: Databases page → Add database → type a path → confirm the entry appears and the database opens.
3. **Import assets (menu)**: File → Import Assets → pick a folder → confirm import progress appears and completes.
4. **Import assets (drag-drop)**: drag a folder onto the import area → confirm it bypasses the picker and imports.
5. **Save single asset**: open an asset → Download → confirm save dialog → confirm file is saved and "Downloaded" toast fires.
6. **Save multiple assets**: select multiple → Download → confirm folder picker → confirm all files saved.
7. **Replicate database**: confirm the existing flow still works (regression check — already on the new pattern).

## Notes

- **Why is the renderer-side `TaskQueue` the right abstraction?** It already exists, it already routes through the `ElectronRendererQueueBackend` singleton registered at app startup, it already tracks taskId ownership so callbacks are scoped correctly, and it already supports `awaitTask`. The replicate-database refactor proved this is a clean fit — no new infrastructure required. Adding a wrapper method on `IPlatformContext` for each task type reintroduces the duplication this plan removes.
- **Why keep `onTaskComplete` branches in main?** They mutate `databases.json` (a main-only file) and fire `show-notification` IPCs. They are reaction code triggered by *any* task completion regardless of source, so moving them to the renderer would mean every queueing site has to subscribe to its own completion just to fire a notification. The current setup is correct: one centralised reaction layer in main, many independent queueing sites in the renderer.
- **Why no `awaitTask` on `IQueueBackend`?** `awaitTask` is on `TaskQueue` (the high-level wrapper), not `IQueueBackend` (the low-level transport). That's deliberate — `IQueueBackend` is callback-based; `TaskQueue` adds promise-shaped sugar on top. The renderer-side flows that want await semantics create a `TaskQueue` and use `queue.awaitTask(taskId)`.
- **Test control server.** Runs in main and uses `workerPool` directly. The Step 6 refactor will need to give it a small `awaitTask`-style helper — either a new method on `WorkerPoolElectronMain` or an inline `onTaskComplete` subscription. Either is fine; pick whichever keeps the test control server file small.
- **What this plan does not change.** CRUD-style handlers (`vault-*`, `add-database`, `get-config`, `get-database-secrets`, etc.), the LAN-share handlers (which manage long-lived sender/receiver state and need request/response semantics that don't fit the task-queue model), the filesystem check handlers (`check-database-exists`, `list-s3-dirs`), and the menu/window plumbing. These are not background tasks and stay dedicated.
- **`open-file`.** Out of scope (see Inventory). It is a picker + a one-line `database-opened` send. Folding it into `pickFolder` + `notifyDatabaseOpened` is a tiny separate refactor unrelated to the task-handler duplication this plan targets.
