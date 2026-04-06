# Plan: Periodic Database Sync with Origin

## Context

Photosphere desktop databases can be replicas of an "origin" database (stored in `.db/config.json` as `IDatabaseConfig.origin`). Currently, no automatic sync runs between local and origin. This plan adds:
- A worker task that performs bidirectional sync via the existing `syncDatabases()` function
- Main-process scheduling: debounce sync on edits (10 s), periodic sync every 5 min
- Connectivity guard: origin must be accessible before sync runs
- Frontend notification: `sync-started` / `sync-completed` IPC events drive an `isSyncing` state shown in the navbar as "Syncing" + spinner

---

## Files

| # | File | Change |
|---|------|--------|
| 1 | `packages/api/src/lib/sync-database.types.ts` | NEW — shared input/output interfaces |
| 2 | `packages/api/src/lib/sync-database.worker.ts` | NEW — task handler |
| 2b | `packages/api/src/lib/media-file-database.ts` | Add `checkConnectivity(databasePath)` |
| 3 | `packages/api/src/lib/task-handlers.ts` | Register `sync-database` |
| 4 | `packages/electron-defs/src/lib/electron-api.ts` | Add `notifyDatabaseEdited` |
| 5 | `apps/desktop/src/preload.ts` | Expose `notifyDatabaseEdited` IPC |
| 6 | `apps/desktop/src/main.ts` | Sync scheduling, IPC handler, task hooks |
| 7 | `packages/user-interface/src/context/platform-context.tsx` | Required sync methods on `IPlatformContext` |
| 8 | `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` | Implement sync event subscriptions |
| 6b | `apps/dev-server/src/index.ts` | Sync scheduling via WebSocket (mirrors main.ts logic) |
| 8b | `apps/dev-frontend/src/lib/platform-provider-web.tsx` | Implement sync event subscriptions via WebSocket |
| 9 | `packages/user-interface/src/context/asset-database-source.tsx` | `isSyncing` state, call edit notification |
| 10 | `packages/user-interface/src/components/navbar.tsx` | Show "Syncing" + spinner |

---

## Step 1 — `packages/api/src/lib/sync-database.types.ts` (new)

```typescript
export interface ISyncDatabaseData {
    // Absolute path to the local replica database.
    databasePath: string;
}

export interface ISyncDatabaseResult {
    // True if a sync actually ran; false if skipped.
    synced: boolean;
    // Human-readable reason when synced === false.
    skippedReason?: string;
}
```

---

## Step 2 — `packages/api/src/lib/sync-database.worker.ts` (new)

```typescript
import type { ITaskContext } from "task-queue";
import { createStorage } from "storage";
import { createMediaFileDatabase, checkConnectivity } from "./media-file-database";
import { loadDatabaseConfig, updateDatabaseConfig } from "./database-config";
import { syncDatabases } from "./sync";
import type { ISyncDatabaseData, ISyncDatabaseResult } from "./sync-database.types";

export async function syncDatabaseHandler(
    data: ISyncDatabaseData,
    context: ITaskContext
): Promise<ISyncDatabaseResult> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const { storage: localStorage, rawStorage: localRawStorage } =
        createStorage(data.databasePath, undefined, undefined);

    const config = await loadDatabaseConfig(localRawStorage);
    if (!config?.origin) {
        return { synced: false, skippedReason: "no origin configured" };
    }

    const connected = await checkConnectivity(config.origin);
    if (!connected) {
        return { synced: false, skippedReason: "origin not accessible" };
    }

    context.sendMessage({ type: "sync-started", databasePath: data.databasePath });

    const { storage: originStorage, rawStorage: originRawStorage } =
        createStorage(config.origin, undefined, undefined);

    const localDb = createMediaFileDatabase(localStorage, uuidGenerator, timestampProvider);
    const originDb = createMediaFileDatabase(originStorage, uuidGenerator, timestampProvider);

    // source = local, target = origin.
    // syncDatabases pulls target→source then pushes source→target.
    // So local receives origin changes, then origin receives local changes.
    await syncDatabases(
        localStorage,
        localRawStorage,
        localDb.bsonDatabase,
        originStorage,
        originRawStorage,
        originDb.bsonDatabase,
        sessionId
    );

    await updateDatabaseConfig(localRawStorage, {
        lastSyncedAt: new Date().toISOString(),
    });

    context.sendMessage({ type: "sync-completed", databasePath: data.databasePath });

    return { synced: true };
}
```

**Note on `syncDatabases` argument order:** The function's pull phase copies `targetAssetStorage → sourceAssetStorage`. Passing `source=local, target=origin` means pull copies origin→local and push copies local→origin — the correct bidirectional sync.

---

## Step 2b — `packages/api/src/lib/media-file-database.ts`

Add a simple reachability check for any database path. The caller decides which path to check — to test origin connectivity, the caller loads the config and passes the origin path.

```typescript
//
// Returns true if the database at the given path is accessible.
// Works for any storage path (local filesystem, S3, network).
// Used by sync scheduling to avoid queuing tasks when the target is unreachable.
//
export async function checkConnectivity(databasePath: string): Promise<boolean> {
    try {
        const { storage } = createStorage(databasePath, undefined, undefined);
        return await merkleTreeExists(storage);
    }
    catch {
        return false;
    }
}
```

Imports needed in `media-file-database.ts` (add if not already present):
- `merkleTreeExists` from `./tree`

---

## Step 3 — `packages/api/src/lib/task-handlers.ts`

Add to imports:
```typescript
import { syncDatabaseHandler } from "./sync-database.worker";
```

Add inside `initTaskHandlers()`:
```typescript
registerHandler("sync-database", syncDatabaseHandler);
```

---

## Step 4 — `packages/electron-defs/src/lib/electron-api.ts`

Add to `IElectronAPI`:
```typescript
//
// Notifies the main process that the database was edited.
// The main process debounces this signal and triggers a background sync.
//
notifyDatabaseEdited: () => void;
```

---

## Step 5 — `apps/desktop/src/preload.ts`

Add to the `electronAPI` object literal:
```typescript
notifyDatabaseEdited: (): void => {
    ipcRenderer.send('notify-database-edited');
},
```

---

## Step 6 — `apps/desktop/src/main.ts`

### New module-level variables (add near existing `isDatabaseOpen` etc.)

```typescript
// Path of the currently open database; null when none.
let currentDatabasePath: string | null = null;

// Debounce timer for edit-triggered sync (10 seconds).
let syncDebounceTimer: NodeJS.Timeout | null = null;

// Periodic sync timer (5 minutes), started after assets finish loading.
let syncPeriodicTimer: NodeJS.Timeout | null = null;

// Prevents concurrent sync tasks; set by enqueueSyncTask(), cleared by syncStopped().
let isSyncRunning: boolean = false;
```

### New helpers `startPeriodicSync()`, `stopPeriodicSync()`, `scheduleDebouncedSync()`, `enqueueSyncTask()`, `syncStopped()`

`enqueueSyncTask` is synchronous — connectivity checking and `sync-started`/`sync-completed` messaging are the worker's responsibility. The `isSyncRunning` flag prevents concurrent syncs: it is set to `true` inside `enqueueSyncTask` before the task is queued, and reset to `false` via `syncStopped()` when the task finishes (whether it succeeded, was skipped, or failed). Because `enqueueSyncTask` checks `isSyncRunning` before setting it, and both operations happen synchronously on the Node.js event loop, there is no race condition.

```typescript
function enqueueSyncTask(): void {
    if (!currentDatabasePath || !taskQueue || isSyncRunning) {
        return;
    }
    isSyncRunning = true;
    taskQueue.addTask("sync-database", { databasePath: currentDatabasePath }, currentDatabasePath);
}

function syncStopped(): void {
    isSyncRunning = false;
}

function scheduleDebouncedSync(): void {
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
    }
    syncDebounceTimer = setTimeout(() => {
        syncDebounceTimer = null;
        enqueueSyncTask();
    }, 10_000);
}

function startPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        return;
    }
    syncPeriodicTimer = setInterval(() => {
        enqueueSyncTask();
    }, 5 * 60 * 1_000);
}

function stopPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        clearInterval(syncPeriodicTimer);
        syncPeriodicTimer = null;
    }
}
```

### New IPC handler for `notify-database-edited`

Add alongside existing `ipcMain.on` handlers:
```typescript
ipcMain.on('notify-database-edited', () => {
    scheduleDebouncedSync();
});
```

### Update `notify-database-opened` handler

Add these lines at the end of the existing handler body:
```typescript
currentDatabasePath = databasePath;
syncStopped();
if (syncDebounceTimer !== null) {
    clearTimeout(syncDebounceTimer);
    syncDebounceTimer = null;
}
```

### Update `notify-database-closed` handler

Add at the end:
```typescript
currentDatabasePath = null;
syncStopped();
if (syncDebounceTimer !== null) {
    clearTimeout(syncDebounceTimer);
    syncDebounceTimer = null;
}
```

### Start periodic sync at app startup

Call `startPeriodicSync()` once during app initialisation, inside `app.whenReady().then(...)` after `initWorkers()`:

```typescript
startPeriodicSync();
```

The timer runs for the lifetime of the app. `enqueueSyncTask` is a no-op when `currentDatabasePath` is null or `isSyncRunning` is true, so ticks that fire while no database is open or while a sync is already in progress are harmless.

### Update `initWorkers()` — extend task callbacks

Extend the existing `onTaskComplete` callback to reset `isSyncRunning`. If the sync task failed (worker threw before sending `sync-completed`), also send `sync-completed` to unblock the frontend:

```typescript
taskQueue.onTaskComplete<ITask<any>, any>((task, result) => {
    if (mainWindow) {
        mainWindow.webContents.send('task-completed', {
            taskId: result.taskId,
            result
        });
    }
    if (task.type === "sync-database") {
        syncStopped();
        if (result.status !== TaskStatus.Succeeded && mainWindow) {
            mainWindow.webContents.send('sync-completed');
        }
    }
});
```

Extend the existing `onAnyTaskMessage` callback to relay `sync-started` and `sync-completed` as top-level IPC events (in addition to forwarding them as `task-message`):

```typescript
taskQueue.onAnyTaskMessage((data) => {
    if (mainWindow) {
        mainWindow.webContents.send('task-message', {
            taskId: data.taskId,
            message: data.message
        });
        if (data.message.type === "sync-started") {
            mainWindow.webContents.send('sync-started');
        }
        else if (data.message.type === "sync-completed") {
            mainWindow.webContents.send('sync-completed');
        }
    }
});
```

Add `TaskStatus` to the task-queue import:
```typescript
import { TaskQueue, TaskStatus } from 'task-queue';
```

### Update `before-quit` handler

Add cleanup before the existing shutdown logic:
```typescript
stopPeriodicSync();
if (syncDebounceTimer !== null) {
    clearTimeout(syncDebounceTimer);
    syncDebounceTimer = null;
}
```

---

## Step 7 — `packages/user-interface/src/context/platform-context.tsx`

Add three required members to `IPlatformContext`:

```typescript
//
// Notifies the platform that the user has edited the database.
// Used to trigger a debounced background sync.
//
notifyDatabaseEdited: () => void;

//
// Subscribes to sync-started events. Returns an unsubscribe function.
//
onSyncStarted: (callback: () => void) => Unsubscribe;

//
// Subscribes to sync-completed events. Returns an unsubscribe function.
//
onSyncCompleted: (callback: () => void) => Unsubscribe;
```

---

## Step 8 — `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`

### Add two callback refs (after existing ones)

```typescript
const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());
const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());
```

### Add two `useEffect` hooks (after existing theme-changed effect)

```typescript
useEffect(() => {
    const handleSyncStarted = () => {
        syncStartedCallbacksRef.current.forEach(cb => cb());
    };
    electronAPI.onMessage('sync-started', handleSyncStarted);
    return () => { electronAPI.removeAllListeners('sync-started'); };
}, [electronAPI]);

useEffect(() => {
    const handleSyncCompleted = () => {
        syncCompletedCallbacksRef.current.forEach(cb => cb());
    };
    electronAPI.onMessage('sync-completed', handleSyncCompleted);
    return () => { electronAPI.removeAllListeners('sync-completed'); };
}, [electronAPI]);
```

### Add three `useCallback` implementations (after existing ones)

```typescript
const notifyDatabaseEdited = useCallback((): void => {
    electronAPI.notifyDatabaseEdited();
}, [electronAPI]);

const onSyncStarted = useCallback((callback: () => void): (() => void) => {
    syncStartedCallbacksRef.current.add(callback);
    return () => { syncStartedCallbacksRef.current.delete(callback); };
}, []);

const onSyncCompleted = useCallback((callback: () => void): (() => void) => {
    syncCompletedCallbacksRef.current.add(callback);
    return () => { syncCompletedCallbacksRef.current.delete(callback); };
}, []);
```

### Add to `platformContext` object

```typescript
notifyDatabaseEdited,
onSyncStarted,
onSyncCompleted,
```

---

## Step 6b — `apps/dev-server/src/index.ts`

The dev-server mirrors the Electron main-process sync scheduling, but uses WebSocket messaging instead of IPC. All sync state is **per-connection** (defined inside `wss.on("connection", ...)`) so it is automatically cleaned up when the client disconnects.

### Add per-connection sync state (inside the connection handler, before the `queue` variable)

```typescript
let currentDatabasePath: string | null = null;
let syncDebounceTimer: NodeJS.Timeout | null = null;
let syncPeriodicTimer: NodeJS.Timeout | null = null;
let isSyncRunning = false;
```

### Add sync helpers (inside the connection handler)

```typescript
function enqueueSyncTask(): void {
    if (!currentDatabasePath || isSyncRunning) {
        return;
    }
    isSyncRunning = true;
    queue.addTask("sync-database", { databasePath: currentDatabasePath }, currentDatabasePath);
}

function scheduleDebouncedSync(): void {
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
    }
    syncDebounceTimer = setTimeout(() => {
        syncDebounceTimer = null;
        enqueueSyncTask();
    }, 10_000);
}

function startPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        return;
    }
    syncPeriodicTimer = setInterval(() => {
        enqueueSyncTask();
    }, 5 * 60 * 1_000);
}

function stopPeriodicSync(): void {
    if (syncPeriodicTimer !== null) {
        clearInterval(syncPeriodicTimer);
        syncPeriodicTimer = null;
    }
}
```

Call `startPeriodicSync()` immediately after the connection is established (early in the `wss.on("connection", ...)` handler, after the state variables are declared).

The timer runs for the lifetime of the connection. `enqueueSyncTask` is a no-op when `currentDatabasePath` is null.

### Extend `onTaskComplete` callback (inside the connection handler)

Reset `isSyncRunning` on sync completion. Send `sync-completed` if the task failed (worker didn't send it):

```typescript
const unsubscribeTaskComplete = queue.onTaskComplete(async (task, result) => {
    ws.send(JSON.stringify({
        type: "task-completed",
        taskId: result.taskId,
        task: { ... }, // existing fields unchanged
        result: result,
    }));
    if (task.type === "sync-database") {
        syncStopped();
        if (result.status !== TaskStatus.Succeeded) {
            ws.send(JSON.stringify({ type: "sync-completed" }));
        }
    }
});
```

Add `TaskStatus` to the import:
```typescript
import { TaskStatus } from "task-queue";
```

### Relay `sync-started`/`sync-completed` from `onAnyTaskMessage`

Extend the existing `unsubscribeTaskMessage` setup to detect and relay sync events:

```typescript
const unsubscribeTaskMessage = queue.onAnyTaskMessage(data => {
    ws.send(JSON.stringify({
        type: "task-message",
        ...data,
    }));
    if (data.message.type === "sync-started") {
        ws.send(JSON.stringify({ type: "sync-started" }));
    }
    else if (data.message.type === "sync-completed") {
        ws.send(JSON.stringify({ type: "sync-completed" }));
    }
});
```

### Handle `notify-database-edited` in the message handler

Add inside `ws.on("message", ...)`:
```typescript
else if (messageData.type === "notify-database-edited") {
    scheduleDebouncedSync();
}
```

### Capture database path on `add-recent-database` / clear on `clear-last-database`

In the existing `handleAddRecentDatabase` call site (where `add-recent-database` is handled), capture the database path and reset sync state:

```typescript
else if (messageData.type === "add-recent-database") {
    currentDatabasePath = messageData.databasePath;
    syncStopped();
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
        syncDebounceTimer = null;
    }
    await handleAddRecentDatabase(ws, messageData.databasePath);
}
```

In the existing `clear-last-database` handler:
```typescript
else if (messageData.type === "clear-last-database") {
    currentDatabasePath = null;
    syncStopped();
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
        syncDebounceTimer = null;
    }
    await handleClearLastDatabase(ws);
}
```

### Clean up timers on disconnect

Extend the existing `ws.on("close", ...)` handler:
```typescript
ws.on("close", () => {
    console.log("WebSocket connection closed");
    unsubscribeTaskComplete();
    unsubscribeTaskMessage();
    stopPeriodicSync();
    if (syncDebounceTimer !== null) {
        clearTimeout(syncDebounceTimer);
        syncDebounceTimer = null;
    }
});
```

---

## Step 8b — `apps/dev-frontend/src/lib/platform-provider-web.tsx`

Implement real sync event support using the same WebSocket message pattern already used for `database-opened` / `database-closed`.

### Add two callback refs (alongside existing `openedCallbacksRef`, `closedCallbacksRef`)

```typescript
const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());
const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());
```

### Extend the existing `useEffect` message listener to dispatch sync events

The existing `useEffect` already parses incoming WebSocket messages and dispatches `database-opened` / `database-closed`. Extend it to also handle `sync-started` and `sync-completed`:

```typescript
if (messageData.type === "sync-started") {
    syncStartedCallbacksRef.current.forEach(cb => cb());
}
else if (messageData.type === "sync-completed") {
    syncCompletedCallbacksRef.current.forEach(cb => cb());
}
```

### Add three `useCallback` implementations

```typescript
const notifyDatabaseEdited = useCallback((): void => {
    ws.send(JSON.stringify({ type: "notify-database-edited" }));
}, [ws]);

const onSyncStarted = useCallback((callback: () => void): (() => void) => {
    syncStartedCallbacksRef.current.add(callback);
    return () => { syncStartedCallbacksRef.current.delete(callback); };
}, []);

const onSyncCompleted = useCallback((callback: () => void): (() => void) => {
    syncCompletedCallbacksRef.current.add(callback);
    return () => { syncCompletedCallbacksRef.current.delete(callback); };
}, []);
```

### Add to the `platformContext` object

```typescript
notifyDatabaseEdited,
onSyncStarted,
onSyncCompleted,
```

---

## Step 9 — `packages/user-interface/src/context/asset-database-source.tsx`

### Add `isSyncing` to `IAssetDatabase` interface

```typescript
//
// True while a background sync with the origin database is in progress.
//
isSyncing: boolean;
```

### Add state inside `AssetDatabaseProvider`

```typescript
const [ isSyncing, setIsSyncing ] = useState(false);
```

### Add `useEffect` to subscribe to sync events

Place alongside the existing database-opened/closed subscription:

```typescript
useEffect(() => {
    const unsubscribeStarted = platform.onSyncStarted(() => {
        setIsSyncing(true);
    });
    const unsubscribeCompleted = platform.onSyncCompleted(() => {
        setIsSyncing(false);
        // Reload the gallery to reflect changes synced from origin.
        // loadAssets() fires onReset (clearing stale/deleted assets), then fires
        // onNewItems with the current post-sync database state (new and updated assets).
        if (databasePath) {
            loadAssets(databasePath).catch(err => {
                console.error('Failed to reload assets after sync:', err);
            });
        }
    });
    return () => {
        unsubscribeStarted();
        unsubscribeCompleted();
    };
}, [platform, databasePath]);
```

**Why this covers all three observables:**
- `onReset` — fired by `loadAssets` before queuing the task; clears all current items, so any asset deleted during sync simply won't reappear.
- `onNewItems` — fired incrementally via `asset-page` task messages as `load-assets` runs; delivers new assets from origin and updated assets with their current post-sync data.
- `onItemsDeleted` — deletions are covered by the `onReset` + reload cycle (the gallery is rebuilt without the deleted assets), so explicit `onItemsDeleted` calls are not needed.

### Call `notifyDatabaseEdited` in `persistDatabaseOps`

After the `axios.post(...)` call:
```typescript
platform.notifyDatabaseEdited();
```

### Reset `isSyncing` in `closeDatabase`

Add `setIsSyncing(false);` inside the `closeDatabase` function.

### Add `isSyncing` to the `value` object

```typescript
const value: IAssetDatabase = {
    // ...existing fields...
    isSyncing,
};
```

---

## Step 10 — `packages/user-interface/src/components/navbar.tsx`

### Update the destructure

```typescript
const { isLoading, isSyncing, databasePath, closeDatabase } = useAssetDatabase();
```

### Add syncing indicator after the existing loading indicator block

```tsx
{isSyncing && !isLoading
    && <div className="flex flex-row items-center ml-1 mr-2">
        <span className="text-sm hidden sm:block mr-1">Syncing</span>
        <div className="mx-1 sm:mx-2">
            <Spinner show={true} />
        </div>
    </div>
}
```

The `!isLoading` guard avoids showing both spinners simultaneously (loading takes visual priority during initial load).

---

## Connectivity Recovery

The periodic timer runs every 5 minutes from the moment the database is opened. Each tick calls `enqueueSyncTask`, which calls `checkConnectivity` and silently skips if the origin is unreachable or a sync is already running. When connectivity returns, the next tick (within 5 minutes) automatically syncs. No additional mechanism is needed.

---

## Verification

1. Open a database that has an origin configured in `.db/config.json`
2. Wait for assets to finish loading — periodic sync timer starts (5 min)
3. Make a metadata edit (e.g. star a photo) — sync should trigger ~10 s later
4. Navbar shows "Syncing" + spinner while task runs, disappears when done
5. Open a database with no origin — no sync should trigger; periodic timer still starts but silently skips
6. Open a database with an inaccessible origin — sync skips with `skippedReason: "origin not accessible"`
7. Close database — all timers cleared, `isSyncing` resets to false
