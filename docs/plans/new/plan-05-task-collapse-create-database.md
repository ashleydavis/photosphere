# Part 5: Collapse `create-database` and `create-database-at-path`

**Requires:** [plan-01-task-pickers.md](plan-01-task-pickers.md) to be complete first.

Collapses both `create-database` and `create-database-at-path` handlers. Both currently dispatch work to main and wait for a response -- the renderer-side `queue.awaitTask` makes this redundant. The renderer queues the task, awaits it, then calls `notifyDatabaseOpened` directly. The test control server switches to `workerPool` directly. A `CLAUDE.md` rule is added to prevent new dedicated handlers from creeping back in.

## Step 1 -- Update the renderer: "create at known path"

File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

Replace the `createDatabaseAtPath` implementation (currently at line ~389):

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
    await notifyDatabaseOpened(databasePath);
}, [notifyDatabaseOpened]);
```

Note: use the local `notifyDatabaseOpened` `useCallback` variable directly -- `platform` does not exist at construction time.

## Step 2 -- Update the renderer: "create with picker"

Replace the `createDatabase` implementation (currently at line ~222):

```ts
const createDatabase = useCallback(async () => {
    const databasePath = await pickFolder({
        title: 'Create Database',
        createDirectory: true,
    });
    if (!databasePath) {
        return;
    }
    await createDatabaseAtPath(databasePath);
}, [pickFolder, createDatabaseAtPath]);
```

## Step 3 -- Update the test control server

File: [apps/desktop/src/lib/test-control-server.ts](apps/desktop/src/lib/test-control-server.ts)

The `createDatabaseAtPath` callback currently calls `createDatabaseAtPathDirect`. Switch it to use `workerPool.addTask` plus an inline `onTaskComplete` subscription (or a thin `awaitTask` wrapper on `WorkerPoolElectronMain` if one exists). This keeps the test control server in main and does not go through IPC.

## Step 4 -- Delete the handlers and helpers

- Delete `ipcMain.handle('create-database', ...)` and `createNewDatabase()` from [apps/desktop/src/main.ts](apps/desktop/src/main.ts) (line ~430, ~1440).
- Delete `ipcMain.handle('create-database-at-path', ...)` and `createDatabaseAtPathDirect()` from main (line ~490, ~305).
- The `preload.ts` and `IElectronAPI` already use a generic `invoke`/`send` bridge -- no changes needed there.
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
