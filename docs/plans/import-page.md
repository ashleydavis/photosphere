# Import Page Plan

## Overview

Add a dedicated Import page to the Electron desktop app. The page shows a "Start Import" button initially, displays a live list of imported assets as the import runs, allows the user to cancel, shows a completion toast with a "View Import" shortcut, and provides a "Clear" button to reset the page after the import finishes.

## Summary of Changes

### 1. Extend the `asset-imported` message with `logicalPath`

The import page needs to display a list of what was imported. The `asset-imported` message currently only carries `assetId`. Add `logicalPath` so the page can show the filename.

**File:** `packages/api/src/lib/import.worker.ts`

Change:
```typescript
context.sendMessage({ type: "asset-imported", assetId: data.assetId });
```
To:
```typescript
context.sendMessage({ type: "asset-imported", assetId: data.assetId, logicalPath: data.logicalPath });
```

This is the only API change needed in the worker layer.

---

### 2. Add new IPC events and handler in the Electron main process

**File:** `apps/desktop/src/main.ts`

#### 2a. Store the current import session ID

Add a module-level variable to track the active import session:
```typescript
let currentImportSessionId: string | undefined = undefined;
```

#### 2b. Send `import-started` when an import begins

In `selectAndImportAssets()`, after choosing a folder and before queuing the task, send:
```typescript
mainWindow.webContents.send('import-started', { path: selectedPath });
```
Also store the `sessionId` used in `taskQueue.addTask(...)` into `currentImportSessionId`.

Replace the existing `show-notification` "Importing assets..." toast with the new `import-started` event (the renderer will handle the toast itself from that point on).

#### 2c. Send `import-completed` when the add-paths task finishes

In the existing `taskQueue.onTaskComplete` handler, where `task.type === "add-paths"` is already handled, add an `import-completed` IPC message in the success branch:

```typescript
if (task.type === "add-paths") {
    currentImportSessionId = undefined;
    if (result.status === TaskStatus.Succeeded) {
        mainWindow.webContents.send('import-completed', {
            filesAdded: /* count from completed subtask messages */,
            filesAlreadyAdded: /* ... */,
            filesFailed: /* ... */,
        });
    }
    // ... existing failure notification stays
}
```

The counts come from tallying `task-message` events as they arrive (already forwarded via the `task-message` IPC event). Alternatively, pass the counts through from the `add-paths` task result if it exposes them (check the task result type).

#### 2d. Add a `cancel-import` IPC handler

```typescript
ipcMain.handle('cancel-import', logExceptions(async () => {
    if (currentImportSessionId && taskQueue) {
        taskQueue.cancelSession(currentImportSessionId);
        currentImportSessionId = undefined;
    }
}, 'Error cancelling import'));
```

> **Note:** Check `task-queue`'s public API for the correct cancellation method name (e.g., `cancelSession`, `cancel`). If the API does not exist yet, it needs to be added to the `task-queue` package. The `isCancelled()` callback on `ITaskContext` is already wired up — the queue just needs an external trigger.

---

### 3. Expose new APIs through the Electron preload and `IElectronAPI`

**File:** `packages/electron-defs/src/lib/electron-api.ts`

Add to `IElectronAPI`:
```typescript
// Cancels the active import operation if one is in progress.
cancelImport(): Promise<void>;
```

**File:** `apps/desktop/src/preload.ts`

Add to the `electronAPI` object:
```typescript
cancelImport: (): Promise<void> => ipcRenderer.invoke('cancel-import'),
```

---

### 4. Extend `IPlatformContext` with import events

**File:** `packages/user-interface/src/context/platform-context.tsx`

Add new interfaces and methods to `IPlatformContext`:

```typescript
// Summary data sent when an import finishes.
export interface IImportCompletedData {
    // Number of new files added to the database.
    filesAdded: number;

    // Number of files that were already in the database.
    filesAlreadyAdded: number;

    // Number of files that failed to import.
    filesFailed: number;
}

// A single import progress message forwarded from a worker task.
export interface ITaskMessageData {
    // The worker task message payload (e.g. asset-imported, file-already-added).
    message: any;
}
```

Add to `IPlatformContext`:
```typescript
// Subscribes to import-started events. Returns an unsubscribe function.
onImportStarted: (callback: () => void) => Unsubscribe;

// Subscribes to import-completed events. Returns an unsubscribe function.
onImportCompleted: (callback: (data: IImportCompletedData) => void) => Unsubscribe;

// Subscribes to task-message events forwarded from worker tasks. Returns an unsubscribe function.
onTaskMessage: (callback: (data: ITaskMessageData) => void) => Unsubscribe;

// Cancels the active import, if any.
cancelImport: () => Promise<void>;
```

---

### 5. Implement new platform methods in the Electron provider

**File:** `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`

Following the existing callback-ref pattern used by `onSyncStarted`, `onShowNotification`, etc.:

- Add `importStartedCallbacksRef`, `importCompletedCallbacksRef`, `taskMessageCallbacksRef`
- Wire up `electronAPI.onMessage('import-started', ...)`, `electronAPI.onMessage('import-completed', ...)`, `electronAPI.onMessage('task-message', ...)`
- Implement `onImportStarted`, `onImportCompleted`, `onTaskMessage` callbacks
- Implement `cancelImport` calling `electronAPI.cancelImport()`
- Add all four to the `platformContext` object

---

### 6. Add no-op implementations to the web platform provider

**File:** `apps/dev-frontend/src/lib/platform-provider-web.tsx`

Add stubs:
```typescript
onImportStarted: (_callback) => () => {},
onImportCompleted: (_callback) => () => {},
onTaskMessage: (_callback) => () => {},
cancelImport: async () => {},
```

---

### 7. Create `ImportContext`

**File:** `packages/user-interface/src/context/import-context.tsx` *(new file)*

This context holds all import state so it is accessible from both the Import page and `main.tsx` (which shows the completion toast).

```typescript
// Import status lifecycle.
export type ImportStatus = 'idle' | 'running' | 'completed' | 'cancelled';

// A single imported asset entry shown in the import list.
export interface IImportedAsset {
    // The asset ID as stored in the database.
    assetId: string;

    // The original logical path of the file (e.g. directory/photo.jpg).
    logicalPath: string;
}

// Value provided by ImportContext.
export interface IImportContext {
    // Current import lifecycle status.
    status: ImportStatus;

    // List of assets successfully imported in the current session.
    importedAssets: IImportedAsset[];

    // Count of files that were already in the database.
    filesAlreadyAdded: number;

    // Count of files that failed.
    filesFailed: number;

    // Cancels the running import.
    cancelImport: () => Promise<void>;

    // Resets import state back to idle, clearing the list.
    clearImport: () => void;
}
```

The provider:
- Uses `usePlatform()` to subscribe to `onImportStarted`, `onImportCompleted`, `onTaskMessage`
- On `import-started`: sets `status = 'running'`, resets `importedAssets`, `filesAlreadyAdded`, `filesFailed`
- On `task-message` where `message.type === 'asset-imported'`: appends `{ assetId, logicalPath }` to `importedAssets`
- On `task-message` where `message.type === 'file-already-added'`: increments `filesAlreadyAdded`
- On `import-completed`: sets `status = 'completed'`
- `cancelImport()`: calls `platform.cancelImport()` and sets `status = 'cancelled'`
- `clearImport()`: resets to `status = 'idle'`, clears lists

Export `useImport(): IImportContext` hook.

---

### 8. Mount `ImportContextProvider` in the app

**File:** `apps/desktop-frontend/src/app.tsx`

Wrap the component tree with `ImportContextProvider` (inside `PlatformProviderElectron`, outside `Routes`):

```tsx
<PlatformProviderElectron ...>
    <ImportContextProvider>
        <AppContextProvider>
            ...
        </AppContextProvider>
    </ImportContextProvider>
</PlatformProviderElectron>
```

Also add it to the web frontend app for consistency:

**File:** `apps/dev-frontend/src/app.tsx`

Same wrapping pattern.

---

### 9. Show completion toast in `main.tsx`

**File:** `packages/user-interface/src/main.tsx`

Add a `useEffect` in `__Main` that subscribes to the import context's `status` changing to `'completed'` and shows a toast:

```typescript
const { status: importStatus, importedAssets } = useImport();
const { addToast } = useToast();
const navigate = useNavigate();

useEffect(() => {
    if (importStatus === 'completed') {
        addToast({
            message: `Import complete: ${importedAssets.length} asset${importedAssets.length !== 1 ? 's' : ''} added`,
            color: 'success',
            duration: 0,   // No auto-dismiss — user must acknowledge
            action: {
                label: 'View Import',
                onClick: () => navigate('/import'),
            },
        });
    }
}, [importStatus]);
```

Remove (or do not re-add) the existing `show-notification` "Importing assets..." logic from `selectAndImportAssets` in `main.ts` — the new `import-started` / `import-completed` events replace it.

---

### 10. Create the Import page

**File:** `packages/user-interface/src/pages/import/import-page.tsx` *(new file)*

The page has three visual states driven by `ImportContext.status`:

#### State: `idle`

Show a centered call-to-action:
```
[FileUpload icon]  Import photos
────────────────────────────────
No import in progress.
[ Import photos ] button  →  calls importAssets()
```

Only show the button if `databasePath` is set; otherwise show `NoDatabaseLoaded`.

#### State: `running`

```
Importing…                          [ Cancel ]
────────────────────────────────────────────────
<scrollable list of imported files>
  ✓ photos/holiday/img001.jpg
  ✓ photos/holiday/img002.jpg
  …
```

- The list grows in real-time as `task-message` events arrive.
- The Cancel button calls `importContext.cancelImport()`.
- A spinner or subtle animation indicates activity.

#### State: `completed` or `cancelled`

```
Import complete   (or "Import cancelled")
────────────────────────────────────────────────
Added:          42 files
Already added:   3 files
Failed:          0 files
────────────────────────────────────────────────
<scrollable list — same as running state, now static>

                                    [ Clear ]
```

- The Clear button calls `importContext.clearImport()`, resetting to `idle`.

---

### 11. Register the `/import` route

**File:** `packages/user-interface/src/main.tsx`

```tsx
import { ImportPage } from "./pages/import/import-page";

// Inside Routes:
<Route path="/import" element={<ImportPage />} />
```

---

### 12. Add Import page navigation to the sidebar and navbar

**File:** `packages/user-interface/src/components/left-sidebar.tsx`

Replace the existing `onClick`-based "Import photos" `ListItem` (lines 96–108) with a `NavLink` to `/import` (same style as Gallery/Map links). The page itself now hosts the import button. Keep this link visible only when `databasePath` is set.

```tsx
{databasePath && (
    <NavLink to="/import" onClick={() => setSidebarOpen(false)}>
        {({ isActive }) => (
            <ListItem className={isActive ? "" : "opacity-40"}>
                <ListItemButton>
                    <ListItemDecorator><FileUpload /></ListItemDecorator>
                    <ListItemContent>Import</ListItemContent>
                </ListItemButton>
            </ListItem>
        )}
    </NavLink>
)}
```

**File:** `packages/user-interface/src/components/navbar.tsx`

Add an Import NavLink alongside Gallery and Map (only when `databasePath` is set):
```tsx
{databasePath && (
    <NavLink
        className={({ isActive }) => "mr-1 sm:mr-3" + (isActive ? "" : " opacity-40")}
        to="/import"
    >
        <div className="flex flex-row items-center">
            <FileUpload fontSize="small" />
            <div className="hidden sm:block ml-2">Import</div>
        </div>
    </NavLink>
)}
```

---

### 13. Update `empty-database.tsx`

**File:** `packages/user-interface/src/components/empty-database.tsx`

The existing "Import photos" button calls `importAssets()` directly. Change it to navigate to `/import` instead, so the user lands on the import page and clicks Start from there. This keeps the import flow consistent.

```tsx
import { useNavigate } from "react-router-dom";

const navigate = useNavigate();

<Button onClick={() => navigate('/import')}>
    Import photos
</Button>
```

---

## File Checklist

| File | Change |
|------|--------|
| `packages/api/src/lib/import.worker.ts` | Add `logicalPath` to `asset-imported` message |
| `apps/desktop/src/main.ts` | Add `currentImportSessionId`, send `import-started`/`import-completed`, add `cancel-import` IPC handler |
| `apps/desktop/src/preload.ts` | Expose `cancelImport` |
| `packages/electron-defs/src/lib/electron-api.ts` | Add `cancelImport()` to `IElectronAPI` |
| `packages/user-interface/src/context/platform-context.tsx` | Add `IImportCompletedData`, `ITaskMessageData`, and four new methods to `IPlatformContext` |
| `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` | Implement the four new platform methods |
| `apps/dev-frontend/src/lib/platform-provider-web.tsx` | Add no-op stubs |
| `packages/user-interface/src/context/import-context.tsx` | **New** — `ImportContext`, `ImportContextProvider`, `useImport` |
| `apps/desktop-frontend/src/app.tsx` | Wrap tree with `ImportContextProvider` |
| `apps/dev-frontend/src/app.tsx` | Wrap tree with `ImportContextProvider` |
| `packages/user-interface/src/main.tsx` | Import `useImport`; add completion toast `useEffect`; add `/import` route |
| `packages/user-interface/src/pages/import/import-page.tsx` | **New** — Import page component |
| `packages/user-interface/src/components/left-sidebar.tsx` | Replace import button with NavLink to `/import` |
| `packages/user-interface/src/components/navbar.tsx` | Add Import NavLink (database-gated) |
| `packages/user-interface/src/components/empty-database.tsx` | Navigate to `/import` instead of calling `importAssets()` directly |

---

## Verification

1. `bun run compile` — TypeScript compiles across all packages with no errors.
2. `bun run test` — all existing tests pass; new tests added for `ImportContext`.
3. Manual smoke: open app, open a database, navigate to Import page — "Start Import" button visible.
4. Manual smoke: click Import, pick a folder — status changes to `running`, list populates in real-time.
5. Manual smoke: cancel mid-import — status changes to `cancelled`, list freezes, Cancel button disappears, Clear button appears.
6. Manual smoke: complete import — completion toast appears with "View Import" button; clicking it navigates to `/import`.
7. Manual smoke: click Clear — page resets to idle state with Start Import button.
8. Manual smoke: repeat import session — previous results are cleared and new ones accumulate.
9. Manual smoke: open app with no database — Import link hidden in sidebar and navbar.
