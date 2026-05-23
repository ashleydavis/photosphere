# Part 4: Collapse `import-directories` and `import-files`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Moves asset import into the renderer: `importDirectories` calls `pickFolder` when no paths are given, and `importFiles` calls a new `pickFiles` IPC when no paths are given. Both then queue the `import-assets` task directly via a renderer-side `TaskQueue`. The File menu is rerouted to send a `menu-action` IPC instead of calling `selectAndImportDirectories()` in main. The old handlers and helper functions are deleted. The test control server is untouched (it already calls `workerPool.addTask` directly).

## Step 1 -- Add `pick-files` IPC (open-files dialog)

`pick-file` from Plan 1 is a *save* dialog. Importing files needs a separate *open* multi-file picker.

File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts)

Add next to the `pick-file` handler:

```ts
ipcMain.handle('pick-files', logExceptions(async (_event, title: string) => {
    return await showFilePicker(title);
}, 'Error picking files'));
```

Add `pickFiles` to `IPlatformContext` in [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx):

```ts
// Opens a multi-file picker dialog and returns the chosen paths, or undefined if cancelled.
pickFiles: (title: string) => Promise<string[] | undefined>;
```

Implement in [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx):

```ts
const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
    return await electronAPI.invoke('pick-files', title);
}, [electronAPI]);
```

Stub in [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): return `undefined`.

## Step 2 -- Track `currentDatabasePath` in the renderer provider

The main process currently guards `selectAndImportDirectories` / `selectAndImportFiles` with a `currentDatabasePath` check. Move that guard to the renderer by tracking the open database path as state.

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Add state near the top of the provider component:

```ts
const [currentDatabasePath, setCurrentDatabasePath] = useState<string | undefined>(undefined);
```

In the existing `handleDatabaseOpened` effect, call `setCurrentDatabasePath(databasePath)` alongside the existing subscriber notifications. In the existing `handleDatabaseClosed` effect, call `setCurrentDatabasePath(undefined)`.

## Step 3 -- Update the renderer: `importDirectories`

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `importDirectories` implementation:

```ts
const importDirectories = useCallback(async (paths?: string[]): Promise<IImportSession | undefined> => {
    if (!currentDatabasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        const folder = await pickFolder({ title: 'Import Directory' });
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
    }, sessionId);
    return { importAssetsTaskId, sessionId };
}, [currentDatabasePath, pickFolder]);
```

## Step 4 -- Update the renderer: `importFiles`

Replace the `importFiles` implementation:

```ts
const importFiles = useCallback(async (paths?: string[]): Promise<IImportSession | undefined> => {
    if (!currentDatabasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        resolvedPaths = await pickFiles('Import Files');
        if (!resolvedPaths || resolvedPaths.length === 0) {
            return undefined;
        }
    }

    const sessionId = new RandomUuidGenerator().generate();
    const queue = new TaskQueue(new RandomUuidGenerator(), sessionId);
    queue.onTaskComplete(() => queue.shutdown());
    const importAssetsTaskId = queue.addTask('import-assets', {
        paths: resolvedPaths,
        storageDescriptor: { databasePath: currentDatabasePath },
        sessionId,
        dryRun: false,
    }, sessionId);
    return { importAssetsTaskId, sessionId };
}, [currentDatabasePath, pickFiles]);
```

## Step 5 -- Route the File-menu import through the renderer

File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~1590)

Change the File-menu Import Assets click handler from calling `selectAndImportDirectories()` directly to:

```ts
mainWindow.webContents.send('menu-action', 'import-assets');
```

In the renderer's existing `menu-action` subscriber, handle `'import-assets'` by calling `platform.importDirectories()` (no args -- triggers the picker).

## Step 6 -- Delete the handlers and helpers

- Delete `ipcMain.handle('import-directories', ...)` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~810).
- Delete `ipcMain.handle('import-files', ...)` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~815).
- Delete `selectAndImportDirectories`, `selectAndImportFiles`, and `startImportWithPaths` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Keep the `import-assets` and `add-paths` branches in `onTaskComplete`.
- Leave the test control server's `importAssets` callback alone -- it already calls `workerPool.addTask` directly and does not go through IPC.

## Unit Tests

Add a renderer-side test for `importDirectories` that mocks the queue backend and asserts:
- When `paths` is empty/undefined, `pickFolder` is called with `title: 'Import Directory'`.
- When a folder is returned, `addTask` is called with task type `'import-assets'` and the correct data shape (paths, storageDescriptor, sessionId, dryRun: false).
- When `pickFolder` returns `undefined`, `addTask` is not called and the function returns `undefined`.
- When `paths` is provided, `pickFolder` is NOT called and `addTask` runs with the provided paths.
- When `currentDatabasePath` is undefined, the function returns `undefined` immediately.

Add a renderer-side test for `importFiles` asserting the same shape of behaviour using `pickFiles` instead of `pickFolder`.

Delete any main-process tests that mock `ipcMain.handle('import-directories', ...)` or `ipcMain.handle('import-files', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'import-directories\|import-files' apps/desktop/src/main.ts` no longer shows `ipcMain.handle` calls.
4. `bun run test:electron` passes (including the import-assets smoke test).
5. Human:
   - File -> Import Assets -> pick a folder -> confirm progress appears and completes.
   - Drag a folder onto the import area -> confirm it bypasses the picker and imports directly.
