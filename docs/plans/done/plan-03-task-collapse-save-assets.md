# Part 3: Collapse `save-assets`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) and [plan-02-task-collapse-save-asset.md](done/plan-02-task-collapse-save-asset.md) to be complete first.

## Issues

- [x] **Application logic must NOT go in `platform-provider-electron.tsx`.** The platform provider is a thin IPC bridge — it exposes platform capabilities (pickFolder, IPC invoke, etc.) and nothing more. Orchestration like "show a folder picker, then queue a background task, then show a toast" is application logic and belongs in a context (most naturally `useAssetDatabase`), not in the per-platform provider. This was the load-bearing correction in plan-02; do not regress.
- [x] **Do not construct `new RandomUuidGenerator()` inline.** Plan-02 added a `uuidGenerator: IUuidGenerator` prop on `AssetDatabaseProvider` and exposed it on the `IAssetDatabase` context. All `TaskQueue` instances inside the provider tree must use that injected generator so tests can swap in a deterministic one.
- [x] **Renderer owns the toast.** Plan-02 deleted the `save-asset` branch in main.ts `onTaskComplete` because the renderer's `awaitTask + addToast` covers it. Do the same here — delete the `save-assets-batch` branch in main.ts after wiring the renderer-side toast.
- [x] **Web parity.** Web `pickFolder` currently returns `undefined`, and there is no web-side `save-assets-batch` handler. Either add a web handler that loops the existing web `save-asset` handler (registered by `apps/dev-frontend/src/lib/save-asset-web-handler.ts`), or explicitly document batch download as desktop-only and skip on web.

## Overview

Moves batch asset download orchestration out of the desktop main process and out of the platform providers, into `useAssetDatabase`. The new flow (same on both platforms — web emulates Electron):

- `pickFolder({ folderKey: 'lastDownloadFolder' })` → `TaskQueue.addTask("save-assets-batch", ...)` → `awaitTask` → `addToast`, called from inside the context method.

The old `save-assets` IPC handler in `main.ts` and the `save-assets-batch` branch in `onTaskComplete` are deleted. The `downloadAssets` field is removed from `IPlatformContext`.

## Step 1 — Add `downloadAssets` to `useAssetDatabase`

File: [packages/user-interface/src/context/asset-database-source.tsx](packages/user-interface/src/context/asset-database-source.tsx)

Add a `downloadAssets` method on `IAssetDatabase` alongside the existing `downloadAsset` (added in plan-02):

```ts
//
// Downloads multiple assets to a single folder by showing the folder picker,
// queueing a save-assets-batch task, and surfacing success/partial/failure toasts when it completes.
//
downloadAssets(assets: IDownloadAssetItem[]): Promise<void>;
```

Implementation, placed next to `downloadAsset`:

```ts
async function downloadAssets(assets: IDownloadAssetItem[]): Promise<void> {
    const folderPath = await platform.pickFolder({
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

    const queue = new TaskQueue(uuidGenerator, databasePath!);
    const taskId = queue.addTask("save-assets-batch", { assets: saveItems, folderPath, databasePath: databasePath! });
    const result = await queue.awaitTask(taskId);
    queue.shutdown();

    if (result && result.status === TaskStatus.Succeeded) {
        const { succeededFiles, failedFiles } = result.outputs as { succeededFiles: string[]; failedFiles: Array<{ filename: string; error: string }> };
        const total = succeededFiles.length + failedFiles.length;
        if (failedFiles.length === 0) {
            addToast({
                message: `Downloaded ${total} asset${total !== 1 ? 's' : ''}`,
                color: 'success',
                action: { label: 'Open Folder', onClick: () => platform.openFolder(folderPath) },
            });
        }
        else if (succeededFiles.length === 0) {
            addToast({
                message: `Failed to download ${failedFiles.length} asset${failedFiles.length !== 1 ? 's' : ''}`,
                color: 'danger',
                duration: 8000,
            });
        }
        else {
            addToast({
                message: `Downloaded ${succeededFiles.length} of ${total} assets (${failedFiles.length} failed)`,
                color: 'warning',
                duration: 8000,
                action: { label: 'Open Folder', onClick: () => platform.openFolder(folderPath) },
            });
        }
    }
    else {
        addToast({
            message: `Failed to download assets: ${result?.errorMessage ?? "unknown error"}`,
            color: 'danger',
            duration: 8000,
        });
    }
}
```

The call site in `right-sidebar.tsx` changes from `usePlatform().downloadAssets(assets, databasePath!)` to `useAssetDatabase().downloadAssets(assets)` — the context already owns `databasePath`.

## Step 2 — Remove `downloadAssets` from the platform context and providers

- [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx): delete `downloadAssets` from `IPlatformContext`.
- [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): delete the `downloadAssets` `useCallback` and its entry in the context object literal. The `ISaveAssetItem` import from `api` becomes unused — remove it.
- [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): delete the `downloadAssets` `useCallback` and its entry in the context object literal.

## Step 3 — Delete the obsolete main-process handler and notification branch

- Delete `ipcMain.handle('save-assets', ...)` and its `ISaveAssetsRequest` interface in [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete the `save-assets-batch` branch in `onTaskComplete` in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) — the renderer's `addToast` covers it now (mirrors plan-02's removal of the `save-asset` branch).

## Step 4 — Web parity for `save-assets-batch`

File: [apps/dev-frontend/src/lib/save-asset-web-handler.ts](apps/dev-frontend/src/lib/save-asset-web-handler.ts)

Add a web `save-assets-batch` handler that loops the existing web `save-asset` handler, accumulating succeeded/failed filenames in the same shape the renderer toast expects:

```ts
export interface ISaveAssetsBatchWebData {
    assets: ISaveAssetItem[];
    folderPath: string;
    databasePath: string;
}

export interface ISaveAssetsBatchWebResult {
    succeededFiles: string[];
    failedFiles: Array<{ filename: string; error: string }>;
    folderPath: string;
}

export async function saveAssetsBatchWebHandler(data: ISaveAssetsBatchWebData, context: ITaskContext): Promise<ISaveAssetsBatchWebResult> {
    const succeededFiles: string[] = [];
    const failedFiles: Array<{ filename: string; error: string }> = [];
    for (const item of data.assets) {
        try {
            await saveAssetWebHandler({
                assetId: item.assetId,
                assetType: item.assetType,
                destPath: item.filename,
                contentType: '',
                databasePath: data.databasePath,
            }, context);
            succeededFiles.push(item.filename);
        }
        catch (error: any) {
            failedFiles.push({ filename: item.filename, error: error?.message ?? String(error) });
        }
    }
    return { succeededFiles, failedFiles, folderPath: data.folderPath };
}
```

Update `initWebTaskHandlers` to register both: `registerHandler("save-assets-batch", saveAssetsBatchWebHandler)`.

Note: `contentType` is empty here because batch download items don't carry it; the browser will infer it from the response Content-Type header.

## Unit Tests

Update tests for the inlined download flow, using a mocked queue backend (the same approach as plan-02's `WebSocketQueueBackend` tests):

- When `pickFolder` returns a path, `addTask` is called with task type `"save-assets-batch"` and the correct data shape (`{ assets, folderPath, databasePath }`).
- When `pickFolder` returns `undefined`, `addTask` is not called.
- On success result, a green toast fires with an "Open Folder" action.
- On partial failure, a warning toast fires showing succeeded/failed counts.
- On full failure, a danger toast fires.

Add tests for `saveAssetsBatchWebHandler` in `apps/dev-frontend/src/test/` mirroring the existing `save-asset-web-handler.test.ts`:
- Loops over each asset, calling fetch and triggering one anchor download per item.
- Reports succeeded and failed filenames correctly when individual fetches throw.

Delete any main-process tests that mock `ipcMain.handle('save-assets', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'save-assets' apps/desktop/src/main.ts` no longer shows an `ipcMain.handle` call and no longer shows a `save-assets-batch` branch in `onTaskComplete`.
4. `grep 'TaskQueue\|RandomUuidGenerator' apps/desktop-frontend/src/lib/platform-provider-electron.tsx apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing — neither provider runs orchestration.
5. `grep 'downloadAssets' packages/user-interface/src/context/platform-context.tsx` returns nothing — the method is gone from the platform interface.
6. `grep 'downloadAssets' apps/desktop-frontend/src/lib/platform-provider-electron.tsx apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing.
7. `bun run test:electron` passes (no save-assets-batch smoke test exists today; plan-02's verify wording was incorrect — do not rely on it).
8. Human: select multiple assets, click Download, confirm folder picker defaults to last download folder, confirm all files saved and success toast fires with an "Open Folder" action.
