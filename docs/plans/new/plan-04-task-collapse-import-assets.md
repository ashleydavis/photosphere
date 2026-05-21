# Part 4: Collapse `import-assets`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Moves asset import into the renderer: `importAssets` calls `pickFolder` when no paths are given, then queues the task via a renderer-side `TaskQueue`. The File menu is rerouted to send a `menu-action` IPC instead of calling `selectAndImportAssets()` in main. The old handler, preload bridge, `IElectronAPI.importAssets`, and the `selectAndImportAssets`/`startImportWithPaths` helpers are deleted. The test control server is untouched.

## Step 1 -- Update the renderer

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `importAssets` implementation:

```ts
const importAssets = useCallback(async (paths?: string[]): Promise<IImportSession | undefined> => {
    if (!currentDatabasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        const folder = await electronAPI.pickFolder({ title: 'Import Assets' });
        if (!folder) {
            return undefined;
        }
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

`currentDatabasePath` is already tracked in the provider for asset queries; plumb that existing source rather than adding a new IPC.

## Step 2 -- Route the File-menu import through the renderer

File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~1309)

Change the File-menu Import Assets click handler from calling `selectAndImportAssets()` directly to:

```ts
mainWindow.webContents.send('menu-action', 'import-assets');
```

In the renderer's existing `menu-action` subscriber, handle `'import-assets'` by calling `platform.importAssets()` (no args -- triggers the picker).

## Step 3 -- Delete the handler and helpers

- Delete `ipcMain.handle('import-assets', ...)`, `selectAndImportAssets`, and `startImportWithPaths` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete `importAssets` from [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts).
- Delete `importAssets` from `IElectronAPI` in [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts).
- Keep the `import-assets` and `add-paths` branches in `onTaskComplete`.
- Leave the test control server's import callback alone -- it calls `workerPool.addTask` directly in main and does not go through IPC.

## Unit Tests

Add a renderer-side test for `importAssets` that mocks the queue backend and asserts:
- When `paths` is empty/undefined, `pickFolder` is called with `title: 'Import Assets'`.
- When a folder is returned, `addTask` is called with task type `'import-assets'` and the correct data shape (paths, storageDescriptor, sessionId, dryRun: false).
- When `pickFolder` returns `undefined`, `addTask` is not called and the function returns `undefined`.
- When `paths` is provided, `pickFolder` is NOT called and `addTask` runs with the provided paths.

Delete any main-process tests that mock `ipcMain.handle('import-assets', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'import-assets' apps/desktop/src/main.ts` no longer shows an `ipcMain.handle` call.
4. `bun run test:electron` passes (including the import-assets smoke test).
5. Human:
   - File -> Import Assets -> pick a folder -> confirm progress appears and completes.
   - Drag a folder onto the import area -> confirm it bypasses the picker and imports directly.
