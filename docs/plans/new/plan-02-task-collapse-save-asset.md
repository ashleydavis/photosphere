# Part 2: Collapse `save-asset`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Moves single-asset download into the renderer: `downloadAsset` calls `pickFile`, then queues the `save-asset` task via a renderer-side `TaskQueue`. The old IPC handler is deleted. The `onTaskComplete` notification branch in main is untouched.

## Step 1 -- Update the renderer

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `downloadAsset` implementation (currently at line ~477):

```ts
const downloadAsset = useCallback(async (assetId, assetType, filename, _contentType, databasePath) => {
    const destPath = await pickFile(filename);
    if (!destPath) {
        return;
    }

    const queue = new TaskQueue(new RandomUuidGenerator(), databasePath);
    queue.onTaskComplete(() => queue.shutdown());
    queue.addTask("save-asset", { assetId, assetType, destPath, databasePath });
}, [pickFile]);
```

The "Downloaded" notification is fired by the existing `onTaskComplete` branch in [main.ts](apps/desktop/src/main.ts). The renderer does not need to subscribe to it.

## Step 2 -- Delete the obsolete handler

- Delete `ipcMain.handle('save-asset', ...)` in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~747).
- The `preload.ts` and `IElectronAPI` already use a generic `invoke`/`send` bridge -- no changes needed there.
- Keep the `save-asset` branch in `onTaskComplete` -- it shows the notification regardless of who queued the task.

## Unit Tests

Add a renderer-side test for `downloadAsset` that mocks the queue backend and asserts:
- `pickFile` is called with the correct filename.
- When a path is returned, `addTask` is called with task type `"save-asset"` and the correct data shape.
- When `pickFile` returns `undefined`, `addTask` is not called.

Delete any main-process tests that mock `ipcMain.handle('save-asset', ...)` (check [apps/desktop/src/test](apps/desktop/src/test)).

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'save-asset' apps/desktop/src/main.ts` no longer shows an `ipcMain.handle` call.
4. `bun run test:electron` passes (including the save-asset smoke test).
5. Human: open an asset, click Download, confirm save dialog, confirm file saved and "Downloaded" toast fires.
