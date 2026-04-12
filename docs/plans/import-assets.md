# Plan: Import Assets into Open Database

## Context

The Photosphere desktop app has no way to import photos/videos from the filesystem into an open database. Users currently must use the CLI (`psi add`). This plan adds import capability to the desktop UI and also improves the CLI by refactoring the import pipeline to use the existing background task system.

Two goals:
1. Add an "Import" button to the left sidebar and a `File > Import Assets...` menu item in the desktop app.
2. Show an empty-database state on the Gallery and Map pages ("This database contains no photos." + "Import photos" button) when a database is open but has no assets.

---

## Background: How Import Currently Works

The current import entry point is `addPaths()` in `packages/api/src/lib/import.ts`. It:
- Runs in the calling process (main thread / CLI process)
- Calls `scanPaths()` to find files
- Creates its own `TaskQueue` + worker threads, queues `hash-file` tasks
- Listens for `hash-file` completions in the main thread; if a file is new, queues `import-file`
- Listens for `import-file` completions in the main thread; batches DB writes via `processPendingDatabaseUpdates()` (acquires write lock, updates merkle tree + BSON, releases lock)
- Calls `queue.shutdown()` when done and returns an `IAddSummary`

This design cannot be used from the Electron main process — `scanPaths()` and the import loop can run for minutes. Blocking the main process prevents window management and IPC from working.

---

## Architecture Decision: Refactor to Pure Background Tasks

Rather than introducing a new utility process, refactor the pipeline to use the **existing background task system** (the same worker pool used for `sync-database`, `save-asset`, etc. in `packages/api/src/lib/task-handlers.ts`).

The new pipeline uses three chained tasks. Each step queues the next via `context.queueTask()` — no orchestration needed in the main process:

1. **`add-paths` task** — scans for files, queues one `hash-file` task per file.
2. **`hash-file` task** — hashes the file, checks if it's already in the DB. If new, queues `import-file` itself.
3. **`import-file` task** — uploads asset/thumb/display files, then performs the DB write directly (merkle tree + BSON) under the write lock.

Both the CLI and the desktop app dispatch a single `add-paths` task. Progress is reported via task messages. The CLI awaits `queue.awaitAllTasks()` for its final summary; the desktop uses the existing `onTaskComplete` / `onAnyTaskMessage` infrastructure.

---

## Files to Modify

### 1. `packages/api/src/lib/add-paths.worker.ts` (NEW FILE)

Create the handler for the `add-paths` task. This is where `scanPaths()` moves to.

Input data interface (define at top of file):
```typescript
export interface IAddPathsData {
    paths: string[];
    storageDescriptor: IStorageDescriptor;
    googleApiKey?: string;
    sessionId: string;
    dryRun: boolean;
    s3Config?: IS3Credentials;
}
```

Handler logic:
- Calls `scanPaths(paths, ...)` from `packages/api/src/lib/file-scanner.ts`
- For each file found, check `context.isCancelled()` before calling `context.queueTask(...)` and break out of the loop if true
- For each file found (and not cancelled), calls `context.queueTask('hash-file', { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, s3Config, logicalPath, labels, googleApiKey, sessionId, dryRun, assetId: uuidGenerator.generate() }, storageDescriptor.dbDir)`
  - `hashCacheDir` = `path.join(os.tmpdir(), 'photosphere')`
  - The `IHashFileData` interface is in `packages/api/src/lib/import.worker.ts`
- For each file ignored (scanPaths progress callback), sends `context.sendMessage({ type: 'file-ignored' })`
- For each file scanned (progress callback), sends `context.sendMessage({ type: 'scan-progress', currentPath })`
- Returns `void` when scanning is complete (the queued `hash-file` tasks continue independently)

### 2. `packages/api/src/lib/import.worker.ts` (MODIFY)

**Modify `hashFileHandler`:**

Currently returns `IHashFileResult` to the main thread, which then decides to queue `import-file`. Change so that `hashFileHandler` queues `import-file` itself when the file is new:

- At the start of the handler, check `context.isCancelled()` and return early if true
- When `records.length === 0` (file not in DB), call:
  ```typescript
  context.queueTask('import-file', {
      ...data,
      expectedHash: hashArrayBuffer,
  }, data.storageDescriptor.dbDir);
  ```
- Send `context.sendMessage({ type: 'file-already-added' })` when `records.length > 0`
- Change return type to `void` (the return value is no longer used by an orchestrator)

**Modify `importFileHandler`:**

Currently returns `IImportFileResult` to the main thread for a deferred DB write. Change so that `importFileHandler` performs the DB write itself after uploads succeed.

- At the start of the handler, check `context.isCancelled()` and return early if true

After the uploads complete (after the existing `return { totalSize, assetData }` block), replace the return with the DB write logic. Move this logic from `processPendingDatabaseUpdates()` in `import.ts` into here:

```typescript
// After uploads succeed, write to database directly
const { storage: rawStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);
// Note: createStorage returns { storage, rawStorage } — use rawStorage for write lock and merkle tree

await acquireWriteLock(rawStorage, sessionId, 3); // retry 3 times
try {
    let merkleTree = await retry(() => loadMerkleTree(storage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    // Add asset to merkle tree
    merkleTree = addItem(merkleTree, {
        name: assetData.assetPath,
        hash: Buffer.from(assetData.assetHash, 'hex'),
        length: assetData.assetLength,
        lastModified: assetData.assetLastModified,
    });

    // Add thumbnail if present
    if (assetData.thumbPath) {
        merkleTree = addItem(merkleTree, {
            name: assetData.thumbPath,
            hash: Buffer.from(assetData.thumbHash!, 'hex'),
            length: assetData.thumbLength!,
            lastModified: assetData.thumbLastModified!,
        });
    }

    // Add display if present
    if (assetData.displayPath) {
        merkleTree = addItem(merkleTree, {
            name: assetData.displayPath,
            hash: Buffer.from(assetData.displayHash!, 'hex'),
            length: assetData.displayLength!,
            lastModified: assetData.displayLastModified!,
        });
    }

    if (!dryRun) {
        // Insert metadata record
        const bsonDatabase = new BsonDatabase(storage, '.db/bson', uuidGenerator, timestampProvider);
        const metadataCollection = bsonDatabase.collection<IAsset>('metadata');
        await metadataCollection.insertOne(assetData.assetRecord);
        await retry(() => saveMerkleTree(merkleTree, storage));
        await bsonDatabase.commit();
        await updateDatabaseConfig(rawStorage, { lastModifiedAt: new Date().toISOString() });
    }
}
finally {
    await releaseWriteLock(rawStorage);
}
```

Then send:
```typescript
context.sendMessage({ type: 'asset-imported', assetId: data.assetId });
```

Change return type to `void`.

**Add required imports** to `import.worker.ts`:
- `acquireWriteLock`, `releaseWriteLock` from `./write-lock`
- `loadMerkleTree`, `saveMerkleTree` from `./tree`
- `addItem` from `merkle-tree`
- `BsonDatabase` from `bdb`
- `updateDatabaseConfig` from `./database-config`

### 3. `packages/api/src/lib/task-handlers.ts` (MODIFY)

Register the new `add-paths` handler:
```typescript
import { addPathsHandler } from './add-paths.worker';
// ...
registerHandler('add-paths', addPathsHandler);
```

### 4. `packages/api/src/lib/import.ts` (MODIFY)

The current `addPaths()` function (line 140) does orchestration that is now handled by the task pipeline. Replace it with a thin wrapper that dispatches the `add-paths` task and waits for all tasks to complete:

```typescript
export async function addPaths(
    taskQueueProvider: ITaskQueueProvider,
    storageDescriptor: IStorageDescriptor,
    paths: string[],
    googleApiKey: string | undefined,
    sessionId: string,
    s3Config: IS3Credentials | undefined,
    dryRun: boolean,
    onMessage?: (message: any) => void
): Promise<IAddSummary> {
    const queue = taskQueueProvider.get();

    const summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        filesProcessed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    queue.onAnyTaskMessage((data) => {
        if (data.message.type === 'asset-imported') {
            summary.filesAdded++;
        }
        else if (data.message.type === 'file-already-added') {
            summary.filesAlreadyAdded++;
            summary.filesProcessed++;
        }
        else if (data.message.type === 'file-ignored') {
            summary.filesIgnored++;
        }
        onMessage?.(data.message);
    });

    queue.onTaskComplete((_task, result) => {
        if (result.status === TaskStatus.Failed) {
            summary.filesFailed++;
        }
    });

    queue.addTask('add-paths', {
        paths,
        storageDescriptor,
        googleApiKey,
        sessionId,
        dryRun,
        s3Config,
    } satisfies IAddPathsData, storageDescriptor.dbDir);

    await queue.awaitAllTasks();

    summary.averageSize = summary.filesAdded > 0
        ? Math.floor(summary.totalSize / summary.filesAdded)
        : 0;

    return summary;
}
```

Remove `processPendingDatabaseUpdates()`, `IPendingDatabaseUpdate`, and all the orchestration imports that are no longer needed.

### 5. `apps/cli/src/cmd/add.ts` (MODIFY)

Update the call to `addPaths()` to match the new simplified signature. The progress callback now receives raw task messages instead of a structured `(currentlyScanning, summary)` pair. Update to use the `onMessage` callback:

```typescript
const addSummary = await addPaths(
    taskQueueProvider,
    storageDescriptor,
    paths,
    googleApiKey,
    sessionId,
    s3Config,
    options.dryRun || false,
    (message) => {
        if (message.type === 'scan-progress') {
            writeProgress(`Scanning ${pc.cyan(message.currentPath)} | Abort with Ctrl-C.`);
        }
        else if (message.type === 'asset-imported') {
            writeProgress(`Importing... | Abort with Ctrl-C.`);
        }
    }
);
```

Remove the old large `loadDatabase` call and the parameters that `addPaths` no longer needs (`assetStorage`, `rawAssetStorage`, `bsonDatabase`, `metadataCollection`, `localHashCache`, `sessionTempDir`).

### 6. `packages/electron-defs/src/lib/electron-api.ts` (MODIFY)

Add to `IElectronAPI` interface:
```typescript
//
// Opens a folder picker and imports selected directories into the current database.
//
importAssets(): Promise<void>;
```

### 7. `apps/desktop/src/preload.ts` (MODIFY)

Add to the `electronAPI` object:
```typescript
importAssets: (): Promise<void> => {
    return ipcRenderer.invoke('import-assets');
},
```

### 8. `apps/desktop/src/main.ts` (MODIFY)

**Add `selectAndImportAssets()` function:**
```typescript
async function selectAndImportAssets(): Promise<void> {
    if (!currentDatabasePath) {
        return;
    }

    const selectedPath = await showDirectoryPicker('Import Assets');
    if (!selectedPath) {
        return;
    }

    if (!taskQueue) {
        throw new Error('Task queue not initialized');
    }

    if (mainWindow) {
        mainWindow.webContents.send('show-notification', {
            message: 'Importing assets...',
            color: 'neutral',
            duration: 0, // no auto-dismiss
        });
    }

    const storageDescriptor: IStorageDescriptor = {
        dbDir: currentDatabasePath,
        encryptionKeyPaths: [],
    };

    taskQueue.addTask('add-paths', {
        paths: [selectedPath],
        storageDescriptor,
        googleApiKey: undefined,
        sessionId: randomUUID(),
        dryRun: false,
        s3Config: undefined,
    }, currentDatabasePath);
}
```

**Add to `onTaskComplete` handler** (around line 371, alongside the existing `sync-database` and `save-asset` checks):
```typescript
if (task.type === 'add-paths' && mainWindow) {
    if (result.status === TaskStatus.Succeeded) {
        // Count asset-imported messages to show total — accumulated via onAnyTaskMessage below
    }
    else {
        mainWindow.webContents.send('show-notification', {
            message: `Import failed: ${result.errorMessage || 'Unknown error'}`,
            color: 'danger',
            duration: 8000,
        });
    }
}
```

**Add to `onAnyTaskMessage` handler** (around line 432):
```typescript
if (data.message.type === 'asset-imported' && mainWindow) {
    // Could update a live counter notification here if desired
}
```

For simplicity, send the success notification from a dedicated completion handler. Alternatively, track the count using a module-level counter keyed by `source` (the `currentDatabasePath`).

**Add IPC handler:**
```typescript
ipcMain.handle('import-assets', logExceptions(selectAndImportAssets, 'Error importing assets'));
```

**Add menu item** in `createMenu()` inside the `fileSubmenu`, after the existing "Open Database" item and before the "Close Database" item (which is only shown when `isDatabaseOpen`). Add it when `isDatabaseOpen` is true:

```typescript
if (isDatabaseOpen) {
    fileSubmenu.push(
        { type: 'separator' },
        {
            label: 'Import Assets...',
            accelerator: 'CmdOrCtrl+I',
            click: logExceptions(selectAndImportAssets, 'Error importing assets from menu'),
        },
        { type: 'separator' },
        {
            label: 'Close Database',
            click: logExceptions(closeDatabase, 'Error closing database from menu'),
        }
    );
}
```

**Add imports** at top of `main.ts`:
- `IAddPathsData` from `api` (or wherever it ends up being exported)
- `IStorageDescriptor` from `storage`

### 9. `packages/user-interface/src/context/platform-context.tsx` (MODIFY)

Add to `IPlatformContext`:
```typescript
//
// Opens a folder picker and imports selected directories into the current database.
// Desktop (Electron) only; no-op on web.
//
importAssets(): Promise<void>;
```

### 10. `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` (MODIFY)

Add:
```typescript
const importAssets = useCallback(async (): Promise<void> => {
    await electronAPI.importAssets();
}, [electronAPI]);
```

Include `importAssets` in the `platformContext` object literal.

### 11. `apps/dev-frontend/src/lib/platform-provider-web.tsx` (MODIFY)

Add a no-op stub:
```typescript
const importAssets = useCallback(async (): Promise<void> => {
    // Not supported on web platform.
}, []);
```

Include `importAssets` in the `platformContext` object literal.

### 12. `packages/user-interface/src/components/left-sidebar.tsx` (MODIFY)

- Add `const { importAssets } = usePlatform();` (import `usePlatform` from `../context/platform-context`)
- Add an "Import" `ListItem` button below the "Open database" button, shown only when `databasePath` is defined:

```tsx
{databasePath && (
    <ListItem
        onClick={async () => {
            setSidebarOpen(false);
            await importAssets();
        }}
        >
        <ListItemButton>
            <ListItemDecorator><FileUpload /></ListItemDecorator>
            <ListItemContent>Import photos</ListItemContent>
        </ListItemButton>
    </ListItem>
)}
```

Import `FileUpload` from `@mui/icons-material`.

### 13. `packages/user-interface/src/components/empty-database.tsx` (NEW FILE)

Create analogous to `packages/user-interface/src/components/no-database-loaded.tsx`:

```tsx
import React from 'react';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import FileUploadIcon from '@mui/icons-material/FileUpload';
import { usePlatform } from '../context/platform-context';

//
// Displayed when a database is open but contains no assets, with a prompt to import photos.
//
export function EmptyDatabase() {
    const { importAssets } = usePlatform();

    return (
        <Box
            className="flex items-center justify-center"
            sx={{
                height: 'calc(100vh - 60px)',
            }}
        >
            <Box sx={{ textAlign: 'center' }}>
                <Typography level="h4" sx={{ mb: 2 }}>
                    This database contains no photos.
                </Typography>
                <Typography level="body-md" sx={{ mb: 4, maxWidth: 400, mx: 'auto' }}>
                    Import photos and videos from your filesystem to get started.
                </Typography>
                <Button
                    variant="soft"
                    color="neutral"
                    size="lg"
                    startDecorator={<FileUploadIcon />}
                    onClick={async () => {
                        await importAssets();
                    }}
                    sx={{
                        borderRadius: 's',
                        px: 4,
                    }}
                >
                    Import photos
                </Button>
            </Box>
        </Box>
    );
}
```

### 14. `packages/user-interface/src/pages/gallery/gallery.tsx` (MODIFY)

Add the empty-database check. Currently the file is:
```tsx
{!databasePath && <NoDatabaseLoaded />}
{databasePath && <Gallery />}
```

Change to:
```tsx
import { EmptyDatabase } from '../../components/empty-database';

const { allItems, isLoading } = useGallery();

{!databasePath && <NoDatabaseLoaded />}
{databasePath && !isLoading && allItems().length === 0 && <EmptyDatabase />}
{databasePath && (isLoading || allItems().length > 0) && <Gallery />}
```

### 15. `packages/user-interface/src/pages/map/map-page.tsx` (MODIFY)

Same pattern as gallery. Currently:
```tsx
{!databasePath && <NoDatabaseLoaded />}
{databasePath && <MapView />}
```

Change to:
```tsx
import { EmptyDatabase } from '../../components/empty-database';

const { allItems, isLoading } = useGallery();

{!databasePath && <NoDatabaseLoaded />}
{databasePath && !isLoading && allItems().length === 0 && <EmptyDatabase />}
{databasePath && (isLoading || allItems().length > 0) && <MapView />}
```

---

## Key Implementation Notes

- **Cancellation**: `resetSyncState()` in `main.ts` already calls `taskQueue.cancelTasks(currentDatabasePath)` when the database is closed or a new one is opened. Since all three new tasks are tagged with `storageDescriptor.dbDir` as their source, they will be cancelled automatically. Each handler must poll `context.isCancelled()` — at the start of `hashFileHandler` and `importFileHandler`, and inside the scan loop in `addPathsHandler` before each `queueTask` call — to exit early when cancelled.
- **Write lock safety**: Multiple `import-file` tasks may attempt DB writes concurrently. `acquireWriteLock` / `releaseWriteLock` (in `packages/api/src/lib/write-lock.ts`) already serialise this correctly — each worker acquires the lock independently.
- **All three merkle tree entries**: When writing to the DB in `importFileHandler`, add the main asset, thumbnail (`thumbPath`), and display (`displayPath`) to the merkle tree if present — the existing `processPendingDatabaseUpdates` does all three (lines 72–100 of `import.ts`).
- **Hash cache writes omitted**: The hash cache is currently written after `addPaths()` returns. In the new design, workers load the hash cache read-only (already the case). Writing it back is a performance optimisation and is omitted in this first pass — reads still work.
- **`IAddPathsData` export**: Export the `IAddPathsData` interface from `packages/api/src/index.ts` so `main.ts` can import it.
- **`showDirectoryPicker`** is already defined in `main.ts` at line ~685 and handles window focus and `defaultPath` correctly. No changes needed to it.

---

## Verification

### 1. Compile check
```
bun run compile
```
Must complete with no TypeScript errors.

### 2. Unit tests
Add tests in `packages/api/src/test/`:
- `add-paths.worker.test.ts`: mock `scanPaths` and `context.queueTask`; assert `hash-file` tasks are queued for each file found and `scan-progress` messages are sent.
- `import.worker.test.ts` (extend existing): assert `hashFileHandler` calls `context.queueTask('import-file', ...)` when `filesAlreadyAdded` is false; assert it sends `file-already-added` message when true.
- `import.worker.test.ts` (extend existing): assert `importFileHandler` performs DB write (calls `acquireWriteLock`, `saveMerkleTree`, `bsonDatabase.commit`) after uploads succeed; assert `asset-imported` message is sent.

Run:
```
bun run test
```
All tests must pass.

### 3. CLI smoke tests
The existing `add-*` tests in `apps/cli/smoke-tests.sh` cover `psi add` end-to-end. Run:
```
cd apps/cli && bash smoke-tests.sh
```
All `add-*` tests must pass, confirming the refactored pipeline works from the CLI.

### 4. Desktop Playwright smoke tests
Add new test cases to `apps/desktop/tests/smoke.spec.ts`:
- **Empty database state**: launch app, create a new database via IPC / menu, navigate to `/gallery`, assert the text "This database contains no photos." is visible and the "Import photos" button is present.
- **Import button in sidebar**: open a database that already contains assets, open the sidebar, assert "Import photos" list item is visible.

Run:
```
cd apps/desktop && bun run test:smoke
```
All existing and new Electron desktop smoke tests must pass.
