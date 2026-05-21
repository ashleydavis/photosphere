# Part 3: Collapse `save-assets`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Moves batch asset download into the renderer: `downloadAssets` calls `pickFolder` with `folderKey: 'lastDownloadFolder'`, then queues the `save-assets-batch` task via a renderer-side `TaskQueue`. The old IPC handler, preload bridge, and `IElectronAPI.saveAssets` are deleted. The `onTaskComplete` notification branch in main is untouched.

## Step 1 -- Update the renderer

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `downloadAssets` implementation (currently at line ~455):

```ts
const downloadAssets = useCallback(async (assets, databasePath) => {
    const folderPath = await electronAPI.pickFolder({
        title: 'Choose folder to save assets',
        folderKey: 'lastDownloadFolder',
        createDirectory: true,
    });
    if (!folderPath) {
        return;
    }

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

The success/partial/failure notification is fired by the existing `onTaskComplete` branch in [main.ts](apps/desktop/src/main.ts). The renderer does not need to subscribe to it.

## Step 2 -- Delete the obsolete handler and exports

- Delete `ipcMain.handle('save-assets', ...)` in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~574).
- Delete `saveAssets` from [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts).
- Delete `saveAssets` from `IElectronAPI` in [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts).
- Keep the `save-assets-batch` branch in `onTaskComplete`.

## Unit Tests

Add a renderer-side test for `downloadAssets` that mocks the queue backend and asserts:
- `pickFolder` is called with `folderKey: 'lastDownloadFolder'`.
- When a folder is returned, `addTask` is called with task type `"save-assets-batch"` and the correct data shape (assets array + folderPath).
- When `pickFolder` returns `undefined`, `addTask` is not called.

Delete any main-process tests that mock `ipcMain.handle('save-assets', ...)` (check [apps/desktop/src/test](apps/desktop/src/test)).

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'save-assets' apps/desktop/src/main.ts` no longer shows an `ipcMain.handle` call.
4. `bun run test:electron` passes.
5. Human: select multiple assets, click Download, confirm folder picker defaults to last download folder, confirm all files saved and success toast fires.
