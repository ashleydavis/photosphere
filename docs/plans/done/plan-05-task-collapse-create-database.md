# Part 5: Collapse `create-database` and `create-database-at-path`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) and [plan-02-task-collapse-save-asset.md](done/plan-02-task-collapse-save-asset.md) to be complete first.

## Issues

- [x] **Application logic must NOT go in `platform-provider-electron.tsx`.** Orchestration belongs in a context (`useAssetDatabase`), not in the platform provider. Plan-02 established this; do not regress.
- [x] **Do not construct `new RandomUuidGenerator()` inline.** Use the injected `uuidGenerator` exposed on `useAssetDatabase` (added by plan-02).
- [x] **Consolidate with existing context methods.** `useAssetDatabase` already exposes `selectAndCreateDatabase` (folder picker + create) and `openDatabase(dbPath)`. The new `createDatabase` / `createDatabaseAtPath` orchestration should live in the same context, replacing or merging with those, not duplicating them via the platform provider.
- [x] **CLAUDE.md rule must reflect the established patterns.** The original §5 documented inline `new RandomUuidGenerator()` and orchestration in the provider — both wrong. Rewrite to reflect: orchestration in a context, injected uuidGenerator, platform provider stays a thin IPC bridge.
- [x] **Web is NOT a no-op, and the web `pickFolder` stub must be wired to dev-server before deleting `create-database` server-side.** Today web `createDatabase` sends a `create-database` WebSocket message to dev-server, which shows a directory dialog server-side (`showDirectoryDialog` in `apps/dev-server/src/index.ts`) and creates the database. After this plan, orchestration moves to `useAssetDatabase.createDatabase()` which calls `platform.pickFolder(...)`; with the current web `pickFolder` returning `undefined`, that would silently no-op on web. Step 0 below adds a `pick-folder` WebSocket message on dev-server (wrapping `showDirectoryDialog`) and rewires the web `pickFolder` to forward to it, so the same renderer code works on both platforms. `notifyDatabaseOpened` is already wired and the `create-database` task is already registered in dev-server via `initTaskHandlers`, so no further server-side changes are needed for this plan.

## Overview

Collapses both `create-database` and `create-database-at-path` IPC handlers. Both currently dispatch work to main and wait for a response — the renderer-side `queue.awaitTask` makes this redundant. The renderer queues the task, awaits it, then calls `notifyDatabaseOpened` directly. The orchestration lives in `useAssetDatabase`. The same flow runs on both platforms (web emulates Electron via dev-server). The test control server switches to `workerPool` directly. A `CLAUDE.md` rule is added documenting the correct patterns.

On web, this requires that `platform.pickFolder` actually forwards to dev-server (which already knows how to show a native directory dialog via `showDirectoryDialog`) instead of returning `undefined`. See the web-pickFolder Issue above.

## Step 0 — Wire web `pickFolder` to dev-server

Without this, `useAssetDatabase.createDatabase()` would silently no-op on web after orchestration moves into the renderer.

In [apps/dev-server/src/index.ts](apps/dev-server/src/index.ts), add a `pick-folder` WebSocket message handler that wraps the existing `showDirectoryDialog` helper. The handler accepts the renderer-supplied `IPickFolderOptions` (`title`, `folderKey`, `createDirectory`), reads the default path for `folderKey` from desktop config, calls a generalised version of `showDirectoryDialog` (extend it to take a `title` argument and a `createDirectory` flag — Linux maps `createDirectory` to zenity's natural behaviour and kdialog's `--getexistingdirectory`/`--getsavefilename` accordingly; macOS adds `with prompt` and an `if not exists then mkdir` shim; Windows sets `$folderBrowser.ShowNewFolderButton`). Persist the chosen path under `folderKey` in desktop config (mirroring the Electron `pickFolder` handler in `apps/desktop/src/lib/pickers.ts`). Respond with `{ type: "pick-folder-result", requestId, value: path | undefined }`. User-cancel → `value: undefined`.

In [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx), replace the stub with:

```ts
const pickFolder = useCallback(async (options?: IPickFolderOptions): Promise<string | undefined> => {
    return await sendAndWait<string | undefined>({ type: "pick-folder", options }, "pick-folder-result");
}, [ws]);
```

## Step 1 — Add `createDatabaseAtPath` / `createDatabase` to `useAssetDatabase`

File: [packages/user-interface/src/context/asset-database-source.tsx](packages/user-interface/src/context/asset-database-source.tsx)

`useAssetDatabase` already has `selectAndCreateDatabase` and `openDatabase`. Add or rework two methods:

```ts
async function createDatabaseAtPath(dbPath: string): Promise<void> {
    const queue = new TaskQueue(uuidGenerator, dbPath);
    try {
        const taskId = queue.addTask('create-database', { databasePath: dbPath });
        const result = await queue.awaitTask(taskId);
        if (!result || result.status !== TaskStatus.Succeeded) {
            throw new Error(`create-database task did not succeed: ${result?.errorMessage ?? "unknown error"}`);
        }
    }
    finally {
        queue.shutdown();
    }
    await platform.notifyDatabaseOpened(dbPath);
}

async function createDatabase(): Promise<void> {
    const dbPath = await platform.pickFolder({
        title: 'Create Database',
        createDirectory: true,
    });
    if (!dbPath) {
        return;
    }
    await createDatabaseAtPath(dbPath);
}
```

If a `selectAndCreateDatabase` already exists, fold it into `createDatabase` (one method, not two). Expose both on the `IAssetDatabase` interface and in the context value object.

The call sites (`databases-page.tsx`, file menu handler, etc.) change from `platform.createDatabase(...)` / `platform.createDatabaseAtPath(...)` to `useAssetDatabase().createDatabase(...)` / `useAssetDatabase().createDatabaseAtPath(...)`.

## Step 2 — Remove from `IPlatformContext` and providers

- [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx): delete `createDatabase` and `createDatabaseAtPath` from `IPlatformContext`. These are application orchestration, not platform primitives. `pickFolder` and `notifyDatabaseOpened` stay — those are real platform capabilities.
- [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): delete the `createDatabase` and `createDatabaseAtPath` `useCallback`s and their entries in the context object literal.
- [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): same.

## Step 3 — Update the test control server

File: [apps/desktop/src/lib/test-control-server.ts](apps/desktop/src/lib/test-control-server.ts)

The `createDatabaseAtPath` callback currently calls `createDatabaseAtPathDirect` in main. Switch it to use `workerPool.addTask('create-database', ...)` plus an inline `onTaskComplete` subscription (or a thin `awaitTask` wrapper on `WorkerPoolElectronMain` if one exists). After the task completes, call `notifyDatabaseOpened` on the renderer via the existing IPC message. This keeps the test control server in main and does not go through IPC.

## Step 4 — Delete the handlers and helpers

- Delete `ipcMain.handle('create-database', ...)` and `createNewDatabase()` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- Delete `ipcMain.handle('create-database-at-path', ...)` and `createDatabaseAtPathDirect()` from main.
- The `preload.ts` and `IElectronAPI` already use a generic `invoke`/`send` bridge — no changes needed there.

## Step 5 — Document the patterns in CLAUDE.md

Add to [CLAUDE.md](CLAUDE.md):

> ## Renderer task orchestration
>
> When the renderer needs to start a background task:
> - Put the orchestration in an application context (most naturally `useAssetDatabase`), NOT in `platform-provider-electron.tsx` or `platform-provider-web.tsx`. The platform providers are thin IPC bridges that expose platform capabilities only.
> - Use the injected `uuidGenerator` from `useAssetDatabase()` to construct `TaskQueue` instances. Do NOT call `new RandomUuidGenerator()` inline — tests rely on a single injection point so they can swap in a deterministic generator.
> - Do not add a dedicated `ipcMain.handle('<task-name>', ...)` in main for the task. Native pickers (folder, save-dialog, multi-file open) stay as small focused IPCs on `IPlatformContext`; task dispatch is queue-based.
> - Prefer `awaitTask` + `addToast` in the renderer for task completion side-effects (notifications, navigation). Only keep `onTaskComplete` branches in main.ts when the side-effect genuinely lives in main (e.g. updating `databases.json`).

## Unit Tests

Add tests for `useAssetDatabase.createDatabaseAtPath`, mocking the queue backend:
- `addTask` is called with task type `'create-database'` and the correct `databasePath`.
- `awaitTask` is awaited before `notifyDatabaseOpened` is called.
- `queue.shutdown()` runs in `finally`.
- A failed task result throws.

Add tests for `createDatabase`:
- `pickFolder` is called with `title: 'Create Database'` and `createDirectory: true`.
- When a path is returned, `createDatabaseAtPath` is called with that path.
- When `pickFolder` returns `undefined`, `createDatabaseAtPath` is not called.

Delete any main-process tests that mock `ipcMain.handle('create-database', ...)` or `ipcMain.handle('create-database-at-path', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'create-database' apps/desktop/src/main.ts` no longer shows `ipcMain.handle` calls.
4. `grep 'TaskQueue\|RandomUuidGenerator' apps/desktop-frontend/src/lib/platform-provider-electron.tsx apps/dev-frontend/src/lib/platform-provider-web.tsx` returns nothing.
5. `grep 'createDatabase\|createDatabaseAtPath' packages/user-interface/src/context/platform-context.tsx` returns nothing.
6. `grep -c "^ipcMain.handle" apps/desktop/src/main.ts` is down by 4 net across plans 02–05 (5 handlers removed: save-asset, save-assets, import-directories, import-files, create-database, create-database-at-path; 2 added: pick-file in plan-01, pick-files in plan-04).
7. `bun run test:electron` passes (smoke test `2-create-database` already exercises File → New Database; `17-replicate-database` covers the replicate regression case; ensure both still pass after this plan).
8. There is no web smoke-test harness yet, so the new web `pickFolder` → `create-database` flow is not automatically covered. Either extend `2-create-database` to also drive the dev-server WebSocket path, or open a follow-up to build web smoke-test infrastructure. Do NOT mark this plan done without one of those two outcomes recorded.
