# Part 2: Collapse `save-asset`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

## Issues

- [x] **Application logic must NOT go in `platform-provider-electron.tsx`.** The platform provider is a thin IPC bridge -- it exposes platform capabilities (pickFile, IPC invoke, etc.) and nothing more. Orchestration like "show a save dialog, then queue a background task" is application logic and belongs in `packages/user-interface`, not in the per-platform provider. The previous version of this plan put the new `downloadAsset` body directly in `platform-provider-electron.tsx`; that was wrong and was reverted. The corrected approach below inlines the orchestration into the existing download click handler in `asset-view.tsx` and removes `downloadAsset` from `IPlatformContext` entirely. **Do not reintroduce a `downloadAsset` method on `IPlatformContext`. Do not put `TaskQueue` construction or `pickFile` orchestration inside `platform-provider-electron.tsx` or `platform-provider-web.tsx`.**

## Overview

Moves single-asset download orchestration out of the desktop main process and out of the platform providers, inlining it into the existing download click handler in `asset-view.tsx`. The new flow (same on both platforms, since web emulates Electron):

- `pickFile` (platform primitive) -> `TaskQueue.addTask("save-asset", ...)` at the call site.

The old `save-asset` IPC handler in `main.ts` is deleted. The `onTaskComplete` notification branch in `main.ts` is untouched (the main process still owns notifications, regardless of who queued the task).

## Step 1 -- Remove `downloadAsset` from the platform context

File: [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx)

- Delete the `downloadAsset` field from `IPlatformContext`.
- Keep `downloadAssets` (batch download) for now -- that is handled by a later plan.

The platform context should only expose primitives that genuinely differ by platform at the IPC/browser level. `downloadAsset` is orchestration over `pickFile` + `TaskQueue` (Electron) or `fetch` + anchor click (web), and that orchestration belongs in the application layer.

## Step 2 -- Inline the orchestration at the call site

File: [packages/user-interface/src/components/asset-view.tsx](packages/user-interface/src/components/asset-view.tsx)

No new file and no new hook. The orchestration is a handful of lines and only has one caller, so put it directly in the existing download click handler.

Change `const { downloadAsset, copyToClipboard } = usePlatform();` to pull only `pickFile` and `copyToClipboard` from the platform context, then replace the existing `downloadAsset(...)` call (around line ~79) with the inline flow:

```ts
const destPath = await pickFile(filename);
if (!destPath) {
    return;
}

const queue = new TaskQueue(new RandomUuidGenerator(), databasePath);
queue.onTaskComplete(() => queue.shutdown());
queue.addTask("save-asset", { assetId, assetType, destPath, contentType, databasePath });
```

`databasePath` is already available at the call site via the existing asset-database context -- no new prop or hook is needed.

**Both platforms run the same flow** -- there are no platform branches. The web environment is an emulation of the Electron environment, so the same code naturally works on both. `pickFile` and the `save-asset` task handler both have web implementations that mirror Electron:

- `pickFile` on web returns a destination handle the `save-asset` task handler can write to (established by [plan-01-task-pickers.md](plan-01-task-pickers.md)), or `undefined` if the user cancels.
- The web `save-asset` task handler consumes `{ assetId, assetType, destPath, contentType, databasePath }` the same way the Electron handler does. The old fetch + anchor click code from `platform-provider-web.tsx` moves into this handler (if it is not already there).

The call site has zero knowledge of REST URLs, blobs, or anchor clicks -- that logic, if still needed, lives inside the web `save-asset` task handler, not in the renderer orchestration.

## Step 3 -- Delete `downloadAsset` from the providers

- [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): delete the `downloadAsset` `useCallback`, delete `downloadAsset` from the `platformContext` object literal. Do NOT add `TaskQueue` or `RandomUuidGenerator` imports here.
- [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): delete the `downloadAsset` `useCallback` and remove it from the context object. The old fetch + anchor click body does NOT move into the new hook -- it moves into the web-side `save-asset` task handler (see Step 2). The renderer hook is platform-agnostic.

## Step 4 -- Delete the obsolete main-process handler

- Delete `ipcMain.handle('save-asset', ...)` in [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~714) and its `ISaveAssetRequest` interface.
- The `preload.ts` and `IElectronAPI` already use a generic `invoke`/`send` bridge -- no changes needed there.
- Keep the `save-asset` branch in `onTaskComplete` -- it shows the notification regardless of who queued the task.

## Unit Tests

Update the existing `asset-view.tsx` tests (under `packages/user-interface/src/test/`) to cover the inlined download flow, using a mocked platform context and a mocked queue backend. There is a single code path regardless of platform:

- When `pickFile` returns a path, `addTask` is called with task type `"save-asset"` and the correct data shape (`{ assetId, assetType, destPath, contentType, databasePath }`).
- When `pickFile` returns `undefined`, `addTask` is not called.
- `pickFile` is called with the correct default filename.

Separately, add a test for the web-side `save-asset` task handler (the one that replaces the old fetch + anchor click code from `platform-provider-web.tsx`). Mock `fetch`, `URL.createObjectURL`, and `document.createElement` and verify the handler fulfils the task data shape.

Delete any main-process tests that mock `ipcMain.handle('save-asset', ...)` (check [apps/desktop/src/test](apps/desktop/src/test)).

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'save-asset' apps/desktop/src/main.ts` no longer shows an `ipcMain.handle` call (the `onTaskComplete` branch stays).
4. `grep 'TaskQueue\|RandomUuidGenerator' apps/desktop-frontend/src/lib/platform-provider-electron.tsx` returns nothing -- the platform provider must remain a thin IPC bridge.
5. `grep 'downloadAsset' packages/user-interface/src/context/platform-context.tsx` returns nothing -- the method is gone from the platform interface.
6. `grep 'downloadAsset' apps/desktop-frontend/src/lib/platform-provider-electron.tsx apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing -- neither provider retains the orchestration.
7. `grep 'fetch\|createObjectURL' apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing related to asset download -- the web bytes-handling moved into the web `save-asset` task handler.
8. `bun run test:electron` passes (including the save-asset smoke test).
9. Human: open an asset, click Download, confirm save dialog, confirm file saved and "Downloaded" toast fires.
