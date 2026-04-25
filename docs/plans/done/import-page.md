# Import Page Plan

## Overview

Add a dedicated Import page to the Electron desktop app. The page shows a "Start Import" button initially, displays a live list of imported assets as the import runs, allows the user to cancel, shows a completion toast with a "View Import" shortcut, and provides a "Clear" button to reset the page after the import finishes.

## Background: existing tool-check infrastructure

The `packages/tools` package already exposes `verifyTools()` (`packages/tools/src/lib/tool-verification.ts`), which checks whether `magick` (ImageMagick), `ffprobe`, and `ffmpeg` are on PATH and returns a `ToolsStatus` object:

```typescript
interface ToolsStatus {
    magick:   { available: boolean; version?: string };
    ffprobe:  { available: boolean; version?: string };
    ffmpeg:   { available: boolean; version?: string };
    allAvailable: boolean;
    missingTools: string[];  // e.g. ['ImageMagick', 'ffmpeg']
}
```

The CLI uses `verifyTools()` in `apps/cli/src/lib/ensure-tools.ts` before running the `add` command, and prints platform-specific install instructions from `apps/cli/src/lib/installation-instructions.ts`. The desktop app does not yet check for these tools at all.

The wiki's Getting Started Desktop page (`photosphere.wiki/Getting-Started-Desktop.md`) already documents the dependency requirement. That page's URL can be shown as a link in the install instructions panel.

---

## Summary of Changes

### 1. Add worker messages for import progress

The import page shows every file as a pending row the moment it is picked up by a worker, then transitions it to success, failure, or skipped when the result is known. Four changes are needed in `importFileHandler`:

**File:** `packages/api/src/lib/import.worker.ts`

#### 1a. Send `import-pending` at the top of the handler (after the cancellation check)

```typescript
// Notify the page that this file is now being processed.
context.sendMessage({ type: "import-pending", assetId: data.assetId, logicalPath: data.logicalPath });
```

This fires immediately — before hashing, deduplication, or any upload — so the row appears in the list as soon as a worker picks the task up.

#### 1b. Rename `asset-imported` to `import-success` and add `logicalPath` and `micro`

The `micro` variable is already computed in `importFileHandler` just before the database write (`assetRecord.micro`). Rename the message type for consistency with the other import messages and include the new fields:

Change:
```typescript
context.sendMessage({ type: "asset-imported", assetId: data.assetId });
```
To:
```typescript
context.sendMessage({ type: "import-success", assetId: data.assetId, logicalPath: data.logicalPath, micro });
```

`micro` is `string | undefined` (base64-encoded JPEG). When it is `undefined` (e.g. for a video where no micro was generated), the row falls back to showing the status icon only.

> **Note:** The `asset-imported` message type is also consumed by `packages/api/src/lib/import.ts` (the `addPaths` function that the CLI uses) to count `filesAdded` in `IAddSummary`. Update that handler to match the renamed type.

#### 1c. Send `import-failed` in the catch block before rethrowing

The outer `try/catch` in `importFileHandler` currently logs, cleans up files, and rethrows. Add a message before the rethrow:

```typescript
context.sendMessage({ type: "import-failed", assetId: data.assetId, logicalPath: data.logicalPath });
throw err;
```

This lets the UI mark the row as failed even though the task ultimately errors out.

#### 1d. Send `import-skipped` wherever a file is silently dropped after `import-pending` was already sent

There are two such places in `importFileHandler`:

**Early duplicate check** (after hashing, before any upload): replace the existing `file-already-added` message with `import-skipped`:

```typescript
// Was: context.sendMessage({ type: "file-already-added" });
context.sendMessage({ type: "import-skipped", assetId: data.assetId, logicalPath: data.logicalPath });
return;
```

**Concurrent-duplicate check under the write lock** (the `existingRecords.length > 0` branch that currently only logs): add a message before the early return:

```typescript
log.verbose(`File "${data.logicalPath}" (${assetId}) already inserted by a concurrent import, skipping.`);
context.sendMessage({ type: "import-skipped", assetId: data.assetId, logicalPath: data.logicalPath });
// (no return here — execution falls through to the finally block naturally)
```

Both cases produce a pending row that would otherwise be left unresolved at the end of the import. `import-skipped` resolves the row so the UI can display it with a distinct "skipped" state.

> **Note on `file-already-added`:** The existing `file-already-added` message type is used by `packages/api/src/lib/import.ts` (`addPaths`, the CLI path) to count `filesAlreadyAdded`. Replace that listener with `import-skipped` so the CLI summary stays accurate. The `task-message` stream in the desktop renderer likewise switches from `file-already-added` to `import-skipped`.

---

### 2. Changes to the Electron main process

**File:** `apps/desktop/src/main.ts`

#### 2a. Return `addPathsTaskId` and `sessionId` from `selectAndImportAssets`

The renderer already knows an import is starting because it called `importAssets()` and is awaiting the result. There is no need to send a separate `import-started` event. Instead, change `selectAndImportAssets` to return the two values the renderer needs to manage the session.

`IImportSession` is defined in `packages/electron-defs/src/lib/electron-api.ts` (see section 4) — import it from there rather than redeclaring it locally:

```typescript
import type { IImportSession } from 'electron-defs';

async function selectAndImportAssets(): Promise<IImportSession | undefined> {
    // ... folder picker unchanged ...

    const sessionId = randomUUID();
    const addPathsTaskId = taskQueue.addTask('add-paths', {
        paths: [selectedPath],
        storageDescriptor,
        googleApiKey: undefined,
        sessionId,
        dryRun: false,
        s3Config: undefined,
    } satisfies IAddPathsData, sessionId);  // <-- source = sessionId, not currentDatabasePath

    return { addPathsTaskId, sessionId };
}
```

Remove the existing `show-notification` "Importing assets..." toast — the renderer handles its own UI state from this point on.

The `ipcMain.handle('import-assets', ...)` handler already returns the result of `selectAndImportAssets`, so the returned object flows back to the renderer automatically via Electron's IPC serialisation. Update `IElectronAPI.importAssets()` to return `Promise<IImportSession | undefined>` (see section 4).

**File:** `packages/api/src/lib/add-paths.worker.ts`

The `addPathsHandler` currently queues each `import-file` task with `storageDescriptor.dbDir` as the source. Change it to use `data.sessionId` instead, so all child tasks share the same source as the parent `add-paths` task and are cancelled together:

```typescript
context.queueTask("import-file", {
    ...
} satisfies IHashFileData, data.sessionId);  // <-- was storageDescriptor.dbDir
```

This ensures `cancelTasks(sessionId)` cancels the `add-paths` task and every `import-file` task it has spawned, without touching sync tasks or asset-loading tasks for the same database.

> **Note:** `IAddPathsData` must be updated to include a `sessionId: string` field if it does not already have one — the `data.sessionId` reference in `add-paths.worker.ts` and the `sessionId` field in the task data object above both depend on this.

#### 2b. No new IPC events needed

The renderer tracks completion entirely from the event stream it already receives (`task-message`, `task-completed`). No new IPC signals are required. The `onTaskComplete` handler in `main.ts` retains its existing `add-paths` failure notification:

```typescript
if (task.type === "add-paths") {
    if (result.status !== TaskStatus.Succeeded && mainWindow) {
        mainWindow.webContents.send('show-notification', {
            message: `Import failed: ${result.errorMessage || 'Unknown error'}`,
            color: 'danger',
            duration: 8000,
        });
    }
}
```

No new module-level state is needed in `main.ts`.

---

### 3. Add `check-tools` IPC handler in the main process and expose it through the preload

The tool check must run in the main process (Node.js environment where the tools are on PATH). The renderer calls it on demand when the Import page mounts.

**File:** `apps/desktop/src/main.ts`

Add an import for `verifyTools` from the `tools` package, then register the handler:

```typescript
import { verifyTools } from 'tools';

ipcMain.handle('check-tools', logExceptions(async () => {
    return await verifyTools();
}, 'Error checking tools'));
```

**File:** `packages/electron-defs/src/lib/electron-api.ts`

Update `importAssets` to return the session info the renderer needs, and add `checkTools`. Also export the `IImportSession` and `IToolsStatus` interfaces:

```typescript
export interface IImportSession {
    // Task ID of the add-paths task, for correlating task-completed events.
    addPathsTaskId: string;

    // Source tag for all tasks in this import; pass to cancelTasks() to cancel.
    sessionId: string;
}

export interface IToolStatus {
    available: boolean;
    version?: string;
}

export interface IToolsStatus {
    magick:       IToolStatus;
    ffprobe:      IToolStatus;
    ffmpeg:       IToolStatus;
    allAvailable: boolean;
    missingTools: string[];
}

// On IElectronAPI:
importAssets(): Promise<IImportSession | undefined>;  // was Promise<void>
checkTools(): Promise<IToolsStatus>;
```

> **Note on type duplication:** These types are defined here for the Electron IPC boundary only. The canonical platform-agnostic equivalents are defined in `platform-context.tsx` (section 4). Because TypeScript uses structural typing, `platform-provider-electron.tsx` can return values of the `electron-defs` types where `platform-context.tsx` types are expected without explicit conversion, as long as the shapes remain compatible. If the shapes ever diverge, add an explicit mapping in the provider.

**File:** `apps/desktop/src/preload.ts`

```typescript
checkTools: (): Promise<IToolsStatus> => ipcRenderer.invoke('check-tools'),
// importAssets already exists; Electron serialises the returned object automatically.
```

---

### 4. Extend `IPlatformContext` with `checkTools` and update `importAssets`

**File:** `packages/user-interface/src/context/platform-context.tsx`

Add `checkTools`, update `importAssets`, and add the three new event/cancellation methods:

```typescript
// Checks whether ImageMagick and ffmpeg are available on PATH.
// On web (no-op platform), returns allAvailable: true.
checkTools: () => Promise<IToolsStatus>;

// Updated signature — returns session info so the caller can track progress and cancel.
importAssets: () => Promise<IImportSession | undefined>;

// Subscribe to task messages (worker progress events). Returns an unsubscribe function.
// On web (no-op platform), the returned function is a no-op and the handler is never called.
onTaskMessage: (handler: (taskId: string, message: Record<string, unknown>) => void) => () => void;

// Subscribe to task completion events. Returns an unsubscribe function.
// On web (no-op platform), the returned function is a no-op and the handler is never called.
onTaskComplete: (handler: (taskId: string, result: Record<string, unknown>) => void) => () => void;

// Cancel all tasks associated with the given session ID.
// On web (no-op platform), does nothing.
cancelTasks: (sessionId: string) => Promise<void>;
```

`IImportSession`, `IToolsStatus`, and `IToolStatus` are defined in `platform-context.tsx` (not imported from `electron-defs`) since they are the canonical platform-agnostic types — `user-interface` must not depend on the Electron-specific `electron-defs` package. The `electron-defs` definitions are structurally identical but kept separate for the IPC boundary (see note in section 3).

---

### 5. Implement new platform methods in the Electron provider

**File:** `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`

- Update `importAssets` to return the `IImportSession` from `electronAPI.importAssets()`
- Implement `checkTools` calling `electronAPI.checkTools()`
- Implement `onTaskMessage` by calling `electronAPI.onMessage('task-message', ...)` and returning the unsubscribe function
- Implement `onTaskComplete` by calling `electronAPI.onMessage('task-completed', ...)` and returning the unsubscribe function
- Implement `cancelTasks` calling `electronAPI.cancelTasks(sessionId)`
- Add all five to the `platformContext` object

---

### 6. Add no-op implementations to the web platform provider

**File:** `apps/dev-frontend/src/lib/platform-provider-web.tsx`

Add stubs:
```typescript
checkTools: async () => ({ magick: { available: true }, ffprobe: { available: true }, ffmpeg: { available: true }, allAvailable: true, missingTools: [] }),
importAssets: async () => undefined,  // no-op; updated signature returning IImportSession | undefined
onTaskMessage: (_handler) => () => {},   // no-op; no task workers in web platform
onTaskComplete: (_handler) => () => {},  // no-op; no task workers in web platform
cancelTasks: async (_sessionId) => {},   // no-op; no tasks to cancel in web platform
```

---

### 7. Create `ImportContext`

**File:** `packages/user-interface/src/context/import-context.tsx` *(new file)*

This context holds all import state so it is accessible from both the Import page and `main.tsx` (which shows the completion toast).

```typescript
// Import status lifecycle.
export type ImportStatus = 'idle' | 'running' | 'completed' | 'cancelled';

// Per-item status within the import list.
export type ImportItemStatus = 'pending' | 'success' | 'failure' | 'skipped';

// A single item in the import list.
export interface IImportItem {
    // The asset ID as stored (or attempted to be stored) in the database.
    assetId: string;

    // The original logical path of the file (e.g. photos/holiday/img001.jpg).
    logicalPath: string;

    // Current status of this item's import.
    status: ImportItemStatus;

    // Base64-encoded JPEG micro-thumbnail. Populated when status transitions to 'success'.
    // Undefined while pending, on failure, on skip, or when no thumbnail was generated (e.g. unsupported type).
    micro?: string;
}

// Value provided by ImportContext.
export interface IImportContext {
    // Current import lifecycle status.
    status: ImportStatus;

    // Ordered list of all items seen in the current import session, in arrival order.
    importItems: IImportItem[];

    // Calls platform.importAssets(), records the session, and sets status to 'running'.
    // Returns false if the user cancelled the folder picker (importAssets returned undefined).
    startImport: () => Promise<boolean>;

    // Cancels the running import.
    cancelImport: () => Promise<void>;

    // Resets import state back to idle, clearing the list.
    clearImport: () => void;
}
```

The provider uses `usePlatform()` to call `platform.importAssets()`, which returns the `IImportSession` (`addPathsTaskId` + `sessionId`) the context needs. For per-file progress and completion detection it subscribes via `platform.onTaskMessage(...)` and `platform.onTaskComplete(...)` (added to `IPlatformContext` in section 4). Both return an unsubscribe function; call them inside a `useEffect` and return the unsubscribes as the cleanup.

- **`onTaskMessage` handler** — receives `(taskId, message)`. The event data shape forwarded from `main.ts` is `{ type: string, ... }`. The provider reads `message.type` to identify import worker messages.
- **`onTaskComplete` handler** — receives `(taskId, result)`. The provider compares `taskId` against the recorded `addPathsTaskId` to detect when scanning is done.

On the web platform, `onTaskMessage` and `onTaskComplete` are no-ops that never call the handler. `importAssets()` returns `undefined`, so `startImport()` returns `false` and `ImportContext` stays in `'idle'` state — no special handling is needed.

**Session filtering:** The `task-message` handler must only process messages while `status === 'running'`. This prevents stale events from a previous session (arriving after cancel or clear) from corrupting state, and silently ignores messages from other concurrent task types that happen to share a message-type name.

Transitions applied as events arrive:

| Source | Event / message type | Action |
|---|---|---|
| `startImport()` return value | `IImportSession` | `status = 'running'`; record `addPathsTaskId` and `sessionId`; clear `importItems` |
| `task-message` | `import-pending` | Append `{ assetId, logicalPath, status: 'pending', micro: undefined }` to `importItems` |
| `task-message` | `import-success` | Find item by `assetId`; set `status = 'success'` and `micro` from message; check completion |
| `task-message` | `import-failed` | Find item by `assetId`; set `status = 'failure'`; check completion |
| `task-message` | `import-skipped` | Find item by `assetId`; set `status = 'skipped'`; check completion |
| `task-completed` | `data.taskId === addPathsTaskId` | Set `addPathsDone = true`; check completion |

**Completion check** — run after every `import-success`/`import-failed`/`import-skipped` message and after the `add-paths` task-completed event:

```
if addPathsDone
   && every item in importItems has status !== 'pending'
then status = 'completed'
```

This correctly handles all cases:
- **Zero files**: `importItems` is empty and `addPathsDone` becomes true → completes immediately.
- **Normal case**: fires when the last in-flight item resolves, after scanning is done.
- **Cancelled**: `status` is set to `'cancelled'` immediately by `cancelImport()`, so the check is a no-op even if straggler `task-completed` events arrive afterward.

Note that `filesAlreadyAdded` has been removed from `IImportContext` — skipped files appear as `'skipped'` rows in `importItems` and the completion summary derives the count from there.

`cancelImport()` calls `platform.cancelTasks(sessionId)` (via `usePlatform()`) using the `sessionId` recorded at `startImport` time, then sets `status = 'cancelled'`. Any `import-pending` items that never received a result remain in `'pending'` state (the worker was cancelled before completing them).

`clearImport()` resets to `status = 'idle'`, clears all state.

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
const { status: importStatus, importItems } = useImport();
const { addToast } = useToast();
const navigate = useNavigate();

useEffect(() => {
    if (importStatus === 'completed') {
        const successCount = importItems.filter(item => item.status === 'success').length;
        addToast({
            message: `Import complete: ${successCount} asset${successCount !== 1 ? 's' : ''} added`,
            color: 'success',
            duration: 0,   // No auto-dismiss — user must acknowledge
            action: {
                label: 'View Import',
                onClick: () => navigate('/import'),
            },
        });
        // Note: verify that the existing toast implementation treats duration: 0 as
        // "never auto-dismiss". If it treats 0 as "dismiss immediately", use the
        // sentinel value the toast system expects for permanent toasts instead.
    }
}, [importStatus]);
```

The "Importing assets..." toast was already removed from `selectAndImportAssets` in section 2 — do not re-add it here.

---

### 10. Create the Import page

**File:** `packages/user-interface/src/pages/import/import-page.tsx` *(new file)*

The page has three visual states driven by `ImportContext.status`:

#### State: `idle`

When the Import page mounts (and `databasePath` is set), immediately call `platform.checkTools()` and show a loading indicator while the check runs. The page then branches on the result:

**Sub-state: tools OK**

Show a centered call-to-action:
```
[FileUpload icon]  Import photos
────────────────────────────────
No import in progress.
[ Import photos ] button  →  calls importAssets()
```

**Sub-state: tools missing**

Show an inline installation instructions panel instead of the Start button. The panel is built directly in the component using `process.platform` to select the right commands — mirroring the logic in `apps/cli/src/lib/installation-instructions.ts` but rendered as React JSX. `process.platform` is available in Electron's renderer process because Electron exposes the Node.js `process` global by default (values: `'darwin'`, `'win32'`, `'linux'`).

> **Note:** Verify `process.platform` is accessible in the renderer by checking `webPreferences` in `main.ts` (specifically `nodeIntegration` and `contextIsolation` settings). If it is not available, expose it via `preload.ts`, add `platform: string` to `IElectronAPI` and `IPlatformContext`, and provide a stub (`'web'`) in `platform-provider-web.tsx`.

Example layout when both tools are missing on macOS:

```
⚠️  Required tools are not installed
─────────────────────────────────────────────────
ImageMagick and ffmpeg are required to import photos
and videos.

macOS — Using Homebrew (recommended):
  brew install imagemagick ffmpeg

macOS — Manual:
  • ImageMagick: https://imagemagick.org/script/download.php#macosx
  • ffmpeg: https://evermeet.cx/ffmpeg/

For full instructions see the documentation:
  https://github.com/ashleydavis/photosphere/wiki/Required-Tools

After installing, click the button below to re-check.

[ Check again ]
```

The "Check again" button re-runs `platform.checkTools()` so the user does not need to navigate away and back.

Only show the page at all if `databasePath` is set; otherwise show `NoDatabaseLoaded`.

#### State: `running`

```
Importing…  ⟳                       [ Cancel ]
────────────────────────────────────────────────
<scrollable list, newest items at the bottom>
  ⏳  [   ]  photos/holiday/img001.jpg     (pending — no thumbnail yet)
  ✓   [🖼 ]  photos/holiday/img002.jpg     (success — micro thumbnail shown)
  ✗   [   ]  photos/holiday/corrupt.jpg   (failure — no thumbnail)
  —   [   ]  photos/holiday/img003.jpg     (skipped — already in database)
  ⏳  [   ]  photos/holiday/img004.jpg     (pending)
  …
```

Each row contains:
- A status icon: spinner/clock for `pending`, checkmark for `success`, X for `failure`, dash/minus for `skipped`
- A small thumbnail cell: renders `<img src="data:image/jpeg;base64,{micro}">` when `micro` is present, otherwise an empty/grey placeholder box of the same fixed size so rows stay aligned
- The `logicalPath` (filename or relative path)

New rows appear immediately (as `pending`) when `import-pending` messages arrive. Each row transitions independently as `import-success`, `import-failed`, or `import-skipped` arrives for its `assetId`.

The Cancel button calls `importContext.cancelImport()`.

#### State: `completed` or `cancelled`

```
Import complete   (or "Import cancelled")
────────────────────────────────────────────────
Added:     42 files
Skipped:    3 files
Failed:     0 files
────────────────────────────────────────────────
<scrollable list — same rows, now all resolved>
  ✓  [🖼 ]  photos/holiday/img001.jpg
  ✓  [🖼 ]  photos/holiday/img002.jpg
  ✗  [   ]  photos/holiday/corrupt.jpg
  —  [   ]  photos/holiday/dup.jpg         ← skipped (already in database)
  …
  ⏳ [   ]  photos/holiday/img099.jpg      ← still pending if cancelled mid-run

                                    [ Clear ]
```

Counts are derived from `importItems`:
- **Added** — `status === 'success'`
- **Skipped** — `status === 'skipped'`
- **Failed** — `status === 'failure'`
- **Still pending** — `status === 'pending'` (only non-zero when cancelled mid-run)

Rows that were never resolved (cancelled mid-run) remain with the pending icon and no thumbnail.
The Clear button calls `importContext.clearImport()`, resetting to `idle`.

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

### 13. Create the Required Tools wiki page

**File:** `photosphere.wiki/Required-Tools.md` *(new file, in the sibling wiki repo)*

Create a dedicated wiki page covering:

1. **Why these tools are needed** — Photosphere uses ImageMagick for image processing (resizing, thumbnail generation, micro-thumbnail extraction, dominant colour extraction) and FFmpeg/FFprobe for video processing (thumbnail extraction, metadata reading, duration detection). Without them, importing photos and videos is not possible.

2. **What each tool does**
   - **ImageMagick** (`magick`) — image resizing and conversion; generates display-size images, thumbnails, and micro-thumbnails from photos.
   - **FFprobe** — reads video metadata (duration, resolution, codec) without decoding.
   - **FFmpeg** — extracts a representative frame from videos to use as their thumbnail.

3. **How to install — per platform**

   macOS:
   ```
   # Using Homebrew (recommended)
   brew install imagemagick ffmpeg

   # Using MacPorts
   sudo port install ImageMagick +universal ffmpeg +universal
   ```
   Manual downloads: https://imagemagick.org/script/download.php#macosx and https://evermeet.cx/ffmpeg/

   Windows:
   ```
   # Using Chocolatey (recommended)
   choco install imagemagick ffmpeg

   # Using Scoop
   scoop install imagemagick ffmpeg
   ```
   Manual downloads: https://imagemagick.org/script/download.php#windows and https://www.gyan.dev/ffmpeg/builds/

   Linux (Ubuntu/Debian):
   ```
   sudo apt update && sudo apt install imagemagick ffmpeg
   ```
   Other distros: `dnf install ImageMagick ffmpeg` (Fedora/RHEL), `pacman -S imagemagick ffmpeg` (Arch), `apk add imagemagick ffmpeg` (Alpine).

4. **How to verify installation** — open a terminal and run:
   ```
   magick --version
   ffmpeg -version
   ffprobe -version
   ```
   All three commands should print a version string. If any are missing, re-check that the install location is on your `PATH`.

5. **Troubleshooting PATH issues** — brief notes on ensuring `/usr/local/bin` (macOS/Linux) or the Chocolatey/Scoop bin dirs (Windows) are in `PATH`, and re-launching the app after installing.

The import page's "tools missing" panel links directly to this page:
```
https://github.com/ashleydavis/photosphere/wiki/Required-Tools
```

Also update `Getting-Started-Desktop.md` to replace the brief Dependencies section with a link to the new page.

---

### 14. Update `empty-database.tsx`

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
| `packages/api/src/lib/import.worker.ts` | Add `import-pending`, `import-failed`, and `import-skipped` messages; rename `asset-imported` → `import-success`; add `logicalPath` and `micro` to `import-success`; replace `file-already-added` with `import-skipped` in both duplicate-detection sites |
| `packages/api/src/lib/import.ts` | Update `filesAdded` counter to match renamed `import-success`; update `filesAlreadyAdded` counter to match renamed `import-skipped` |
| `apps/desktop/src/main.ts` | Add `verifyTools` import; add `check-tools` IPC handler; change `selectAndImportAssets` to return `IImportSession`; use `sessionId` as the `add-paths` task source; remove "Importing assets…" toast (no new module-level state needed) |
| `packages/api/src/lib/add-paths.worker.ts` | Use `data.sessionId` (not `storageDescriptor.dbDir`) as the source when queuing `import-file` child tasks |
| `packages/api/src/lib/types.ts` (or wherever `IAddPathsData` is defined) | Add `sessionId: string` field to `IAddPathsData` |
| `apps/desktop/src/preload.ts` | Expose `checkTools` |
| `packages/electron-defs/src/lib/electron-api.ts` | Add `IImportSession`, `IToolStatus`, `IToolsStatus`; update `importAssets()` return type; add `checkTools()` |
| `packages/user-interface/src/context/platform-context.tsx` | Add `IImportSession`, `IToolStatus`, `IToolsStatus`, `checkTools`, `onTaskMessage`, `onTaskComplete`, `cancelTasks`; update `importAssets` return type |
| `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` | Update `importAssets` return type; implement `checkTools`, `onTaskMessage`, `onTaskComplete`, `cancelTasks` |
| `apps/dev-frontend/src/lib/platform-provider-web.tsx` | Update `importAssets` stub to return `undefined`; add stubs for `checkTools`, `onTaskMessage`, `onTaskComplete`, `cancelTasks` |
| `packages/user-interface/src/context/import-context.tsx` | **New** — `ImportContext`, `ImportContextProvider`, `useImport`; `startImport()` calls `platform.importAssets()`; tracks completion via `task-message` and `task-completed`; cancels via `electronAPI.cancelTasks(sessionId)` |
| `apps/desktop-frontend/src/app.tsx` | Wrap tree with `ImportContextProvider` |
| `apps/dev-frontend/src/app.tsx` | Wrap tree with `ImportContextProvider` |
| `packages/user-interface/src/main.tsx` | Import `useImport`; add completion toast `useEffect`; add `/import` route |
| `packages/user-interface/src/pages/import/import-page.tsx` | **New** — Import page component (tool check, idle, running, completed/cancelled states) |
| `packages/user-interface/src/components/left-sidebar.tsx` | Replace import button with NavLink to `/import` |
| `packages/user-interface/src/components/navbar.tsx` | Add Import NavLink (database-gated) |
| `packages/user-interface/src/components/empty-database.tsx` | Navigate to `/import` instead of calling `importAssets()` directly |
| `photosphere.wiki/Required-Tools.md` | **New** — wiki page explaining why tools are needed, how to install per platform, and how to verify |
| `photosphere.wiki/Getting-Started-Desktop.md` | Replace brief Dependencies section with a link to the new Required-Tools page |

---

## Verification

### Automated
1. `bun run compile` — TypeScript compiles across all packages with no errors.
2. `bun run test` — all existing tests pass; new unit tests added for `ImportContext` covering all message-type transitions (import-started, import-pending, import-success, import-failed, import-skipped, import-completed, cancel, clear).
3. `./apps/cli/smoke-tests.sh` — all CLI smoke tests pass, verifying that the worker message renames (`asset-imported` → `import-success`, `file-already-added` → `import-skipped`) and the corresponding counter updates in `import.ts` have not broken CLI import behaviour.

### Manual smoke tests
3. **No database**: open the app without loading a database — Import link is hidden in sidebar and navbar.
4. **Tools present**: open a database, navigate to the Import page — tool check runs, then "Start Import" button appears.
5. **Tools missing** (simulate by temporarily renaming `magick` on PATH): navigate to Import page — installation instructions panel appears for the correct platform; "Start Import" button is absent; clicking "Check again" after restoring the tool shows the Start button.
6. **Wiki link**: the installation instructions panel contains a clickable link to the Required Tools wiki page (`https://github.com/ashleydavis/photosphere/wiki/Required-Tools`); clicking it opens in the system browser.
7. **Happy path import**: click Start Import, pick a folder — status changes to `running`, rows appear as `pending` immediately then transition to `success` with a micro thumbnail as each file completes.
8. **Failed file**: import a folder containing a corrupt or unsupported file — that row transitions to `failure` (no thumbnail, failure icon).
9. **Cancel**: start an import and click Cancel mid-run — status changes to `cancelled`, unresolved rows stay as `pending`, Cancel button is replaced by Clear.
10. **Completion toast**: complete a full import — toast appears with "Import complete: N assets added" and a "View Import" action button; clicking it navigates to `/import`.
11. **Clear**: on the completed/cancelled page, click Clear — page resets to idle with the Start button.
12. **Repeat session**: start a second import immediately after clearing — the list is empty at the start and populates fresh.
13. **Already added**: import the same folder twice — second run shows rows transitioning from `pending` to `skipped` (dash icon, no thumbnail); the completion summary shows the correct Skipped count.
