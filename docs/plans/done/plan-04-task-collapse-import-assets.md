# Part 4: Collapse `import-directories` and `import-files`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) and [plan-02-task-collapse-save-asset.md](done/plan-02-task-collapse-save-asset.md) to be complete first.

## Issues

- [x] **Application logic must NOT go in `platform-provider-electron.tsx`.** The platform provider is a thin IPC bridge. Orchestration like "show a picker, then queue a background task, then return a session handle" is application logic and belongs in a context. Plan-02 established this; do not regress.
- [x] **Do not construct `new RandomUuidGenerator()` inline.** Plan-02 added a `uuidGenerator: IUuidGenerator` prop on `AssetDatabaseProvider` and exposed it on the `IAssetDatabase` context. Use it. Tests inject a deterministic generator through it.
- [x] **Do not duplicate `currentDatabasePath` state in the platform provider.** The original Step 2 in this plan proposed a `useState<string | undefined>` in `platform-provider-electron.tsx` and effects to keep it in sync. That state already exists as `useAssetDatabase().databasePath`. Use it directly.
- [x] **Re-nest providers so `useImport` can read `useAssetDatabase`.** Today `ImportContextProvider` is rendered outside `AssetDatabaseProvider` in both `app.tsx` files. Move it inside so the import orchestration can pull `databasePath`, `uuidGenerator`, and `queueBackend` from `useAssetDatabase`. Nothing currently consumes `useImport` outside the `AssetDatabaseProvider` tree, so re-nesting is safe.
- [x] **`pickFiles` stays on `IPlatformContext`.** Native multi-file open dialog is a genuine platform primitive (like `pickFile`/`pickFolder`), so adding it to the platform context is the right call — that part of the original plan is fine.
- [x] **Web is NOT a no-op.** Web forwards pickers and tasks to dev-server, which shows native dialogs via shell commands (zenity / osascript / PowerShell — see `apps/dev-server/src/index.ts:showDirectoryDialog`) and runs the same node-api task handlers Electron uses (via `initTaskHandlers()` in `WorkerPoolInline`). The web `pickFiles` therefore forwards to a new `pick-files` WebSocket message on dev-server backed by a shell-based multi-file dialog (see Step 1 below), matching how `openDatabase`/`createDatabase` already work. The `import-assets` task already forwards over WebSocket and dev-server already runs the handler, so once orchestration moves to `useImport` the same renderer code works on both platforms.

## Overview

Moves import orchestration out of the desktop main process and out of the platform provider, into `useImport`. The same flow runs on both platforms (web emulates Electron via dev-server):

- `pickFolder({...})` or `pickFiles(...)` → `TaskQueue.addTask("import-assets", ...)` → return `IImportSession` so the caller can subscribe to progress and cancel.

The old `import-directories` / `import-files` IPC handlers and their `selectAndImportDirectories` / `selectAndImportFiles` / `startImportWithPaths` helpers in main.ts are deleted. The `importDirectories` and `importFiles` fields are removed from `IPlatformContext`. The File menu sends a `menu-action` IPC instead of calling helpers in main.

On web, `pickFiles` and the `import-assets` task both forward over WebSocket to dev-server — dev-server shows a native multi-file dialog via shell commands and runs the existing `import-assets` task handler from `node-api`.

## Step 1 — Add `pick-files` IPC (open-files dialog)

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

Implement in [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): forward to dev-server using the existing `sendAndWait` helper:

```ts
const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
    return await sendAndWait<string[] | undefined>({ type: "pick-files", title }, "pick-files-result");
}, [ws]);
```

In [apps/dev-server/src/index.ts](apps/dev-server/src/index.ts) add a `pick-files` WebSocket message handler that shows a native multi-file open dialog using the same shell-based pattern as `showDirectoryDialog`:

- Linux: `zenity --file-selection --multiple --separator='\n'` (or `kdialog --getopenfilename ... --multiple`)
- macOS: `osascript -e 'choose file with multiple selections allowed'`
- Windows: PowerShell `OpenFileDialog` with `Multiselect = $true`

Respond with `{ type: "pick-files-result", requestId, value: paths | undefined }`. Treat user-cancel as `value: undefined` rather than an error.

## Step 2 — Re-nest providers

Files: [apps/desktop-frontend/src/app.tsx](apps/desktop-frontend/src/app.tsx) and [apps/dev-frontend/src/app.tsx](apps/dev-frontend/src/app.tsx)

Move `ImportContextProvider` to be a child of `AssetDatabaseProvider` so `useImport` can call `useAssetDatabase()`. Verify no current `useImport` callers live outside the `AssetDatabaseProvider` tree (grep confirms only `main.tsx` and `import-page.tsx`, both inside the tree).

## Step 3 — Move import orchestration into `useImport`

File: [packages/user-interface/src/context/import-context.tsx](packages/user-interface/src/context/import-context.tsx)

Pull `databasePath`, `uuidGenerator`, and `queueBackend` (or just `uuidGenerator` if you let `TaskQueue` find the backend via the existing singleton) from `useAssetDatabase()`. Replace the indirections through `platform.importDirectories` / `platform.importFiles` with direct orchestration:

```ts
const { databasePath, uuidGenerator } = useAssetDatabase();

async function importDirectories(paths?: string[]): Promise<IImportSession | undefined> {
    if (!databasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        const folder = await platform.pickFolder({ title: 'Import Directory' });
        if (!folder) {
            return undefined;
        }
        resolvedPaths = [folder];
    }

    const sessionId = uuidGenerator.generate();
    const queue = new TaskQueue(uuidGenerator, sessionId);
    queue.onTaskComplete(() => queue.shutdown());
    const importAssetsTaskId = queue.addTask('import-assets', {
        paths: resolvedPaths,
        storageDescriptor: { databasePath },
        sessionId,
        dryRun: false,
    }, sessionId);
    return { importAssetsTaskId, sessionId };
}

async function importFiles(paths?: string[]): Promise<IImportSession | undefined> {
    if (!databasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        resolvedPaths = await platform.pickFiles('Import Files');
        if (!resolvedPaths || resolvedPaths.length === 0) {
            return undefined;
        }
    }

    const sessionId = uuidGenerator.generate();
    const queue = new TaskQueue(uuidGenerator, sessionId);
    queue.onTaskComplete(() => queue.shutdown());
    const importAssetsTaskId = queue.addTask('import-assets', {
        paths: resolvedPaths,
        storageDescriptor: { databasePath },
        sessionId,
        dryRun: false,
    }, sessionId);
    return { importAssetsTaskId, sessionId };
}
```

Then update the existing `startImportDirectories` / `startImportFiles` to call these local functions instead of `platform.importDirectories` / `platform.importFiles`.

## Step 4 — Route the File-menu import through the renderer

File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~1590)

Change the File-menu Import Assets click handler from calling `selectAndImportDirectories()` directly to:

```ts
mainWindow.webContents.send('menu-action', 'import-assets');
```

In the renderer's existing `menu-action` subscriber (in `main.tsx`), handle `'import-assets'` by calling `useImport().startImportDirectories()` (no args — triggers the picker).

## Step 5 — Delete the handlers, helpers, and platform-context fields

- Delete `ipcMain.handle('import-directories', ...)` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete `ipcMain.handle('import-files', ...)` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete `selectAndImportDirectories`, `selectAndImportFiles`, and `startImportWithPaths` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete `importDirectories` and `importFiles` from `IPlatformContext` in [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx).
- Delete the `importDirectories` / `importFiles` `useCallback`s from both platform providers and their entries in each provider's context object literal.
- Keep the `import-assets` and `add-paths` branches in `onTaskComplete` — they handle the success notification, which the existing toast subscriber renders via `show-notification`. (Optionally, move that toast into the renderer the way plan-02 did for `save-asset`; treat that as a follow-up.)
- Leave the test control server's `importAssets` callback alone — it already calls `workerPool.addTask` directly and does not go through IPC.

## Unit Tests

Add tests for the renderer-side `importDirectories` / `importFiles` in `useImport`, using a mocked queue backend:
- When `paths` is empty/undefined, `pickFolder` (or `pickFiles`) is called with the correct title.
- When a folder/files are returned, `addTask` is called with task type `'import-assets'` and the correct data shape (paths, storageDescriptor, sessionId, dryRun: false).
- When the picker returns `undefined`, `addTask` is not called and the function returns `undefined`.
- When `paths` is provided, the picker is NOT called and `addTask` runs with the provided paths.
- When `databasePath` is undefined, the function returns `undefined` immediately.

Delete any main-process tests that mock `ipcMain.handle('import-directories', ...)` or `ipcMain.handle('import-files', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'import-directories\|import-files' apps/desktop/src/main.ts` no longer shows `ipcMain.handle` calls or `selectAndImport*` / `startImportWithPaths` helpers.
4. `grep 'TaskQueue\|RandomUuidGenerator' apps/desktop-frontend/src/lib/platform-provider-electron.tsx apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing — neither provider runs orchestration.
5. `grep 'importDirectories\|importFiles' packages/user-interface/src/context/platform-context.tsx` returns nothing.
6. `bun run test:electron` passes (smoke test `4-import-photos` already exercises File → Import Assets → folder picker → import-assets task; ensure it still covers the renderer-driven path after this plan).
7. There is no web smoke-test harness yet, so the new web `pickFiles` → `import-assets` flow is not automatically covered. Either extend `4-import-photos` to also drive the dev-server WebSocket path, or open a follow-up to build web smoke-test infrastructure. Do NOT mark this plan done without one of those two outcomes recorded.
