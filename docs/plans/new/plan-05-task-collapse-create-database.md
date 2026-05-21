# Part 5: Collapse `create-database` and `create-database-at-path`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Collapses both `create-database` and `create-database-at-path` handlers. Both currently create a throwaway `TaskQueue` in main just to `await` completion -- the renderer-side `queue.awaitTask` makes this redundant. The renderer queues the task, awaits it, then calls `platform.notifyDatabaseOpened` directly. The test control server switches to `workerPool` directly. A `CLAUDE.md` rule is added to prevent new dedicated handlers from creeping back in.

## Step 1 -- Update the renderer: "create at known path"

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `createDatabaseAtPath` implementation:

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

The previous main-side `mainWindow.webContents.send('database-opened', databasePath)` becomes the renderer's own `platform.notifyDatabaseOpened` call -- same downstream effect, no extra IPC.

## Step 2 -- Update the renderer: "create with picker"

Replace the `createDatabase` implementation:

```ts
const createDatabase = useCallback(async () => {
    const databasePath = await electronAPI.pickFolder({
        title: 'Create Database',
        createDirectory: true,
    });
    if (!databasePath) {
        return;
    }
    await createDatabaseAtPath(databasePath);
}, [electronAPI, createDatabaseAtPath]);
```

## Step 3 -- Update the test control server

File: [apps/desktop/src/lib/test-control-server.ts](apps/desktop/src/lib/test-control-server.ts)

The `createDatabaseAtPath` callback currently calls `createDatabaseAtPathDirect`. Switch it to use `workerPool.addTask` plus an inline `onTaskComplete` subscription (or a thin `awaitTask` wrapper on `WorkerPoolElectronMain` if one exists). This keeps the test control server in main and does not go through IPC.

## Step 4 -- Delete the handlers and helpers

- Delete `ipcMain.handle('create-database', ...)` and `createNewDatabase()` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~285, ~1151).
- Delete `ipcMain.handle('create-database-at-path', ...)` and `createDatabaseAtPathDirect()` from main (line ~345, ~331).
- Delete `createDatabase` and `createDatabaseAtPath` from [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts).
- Delete `createDatabase` and `createDatabaseAtPath` from `IElectronAPI` in [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts).
- `platform.createDatabase` and `platform.createDatabaseAtPath` remain on `IPlatformContext` -- they are the cross-platform abstraction, just no longer backed by dedicated IPCs.

## Step 5 -- Document the pattern in CLAUDE.md

Add to [CLAUDE.md](CLAUDE.md):

> When the renderer needs to start a background task, create a `TaskQueue` directly with `new TaskQueue(new RandomUuidGenerator(), source)` and use `queue.addTask(...)`. Do not add a dedicated `ipcMain.handle('<task-name>', ...)` in main, and do not add a wrapper method on `IPlatformContext` for individual task types. Native pickers (folder, save-dialog) stay as small focused IPCs. Task-completion side effects (notifications, `databases.json` updates) live in main's `onTaskComplete` branches and stay there.

## Unit Tests

Add a renderer-side test for `createDatabaseAtPath` that mocks the queue backend and asserts:
- `addTask` is called with task type `'create-database'` and the correct `databasePath`.
- `awaitTask` is awaited before `notifyDatabaseOpened` is called.
- `queue.shutdown()` is called in the finally block.

Add a test for `createDatabase` asserting:
- `pickFolder` is called with `title: 'Create Database'` and `createDirectory: true`.
- When a path is returned, `createDatabaseAtPath` is called with that path.
- When `pickFolder` returns `undefined`, `createDatabaseAtPath` is not called.

Delete any main-process tests that mock `ipcMain.handle('create-database', ...)` or `ipcMain.handle('create-database-at-path', ...)`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'create-database' apps/desktop/src/main.ts` no longer shows `ipcMain.handle` calls.
4. `bun run test:electron` passes.
5. `grep -c "^ipcMain.handle" apps/desktop/src/main.ts` is down by 4 net (5 handlers removed, 1 added in Part 1).
6. Human:
   - File -> New Database -> pick a fresh folder -> gallery opens.
   - Databases page -> Add database -> type a path -> entry appears and database opens.
   - Replicate database still works (regression check).
