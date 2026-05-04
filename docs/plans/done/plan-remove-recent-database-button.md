# Remove Recent Database Button

## Overview
Add a small trash/delete `IconButton` to each recently opened database entry in the left sidebar so the user can remove an entry from the "Databases" recents list without affecting the underlying database registration. The action only edits `recentDatabasePaths` in `~/.config/photosphere/databases.toml`; the database itself (its `databases` entry, files, and secrets) is untouched. The new button mirrors the existing "remove recent search" pattern in [right-sidebar.tsx:537-549](packages/user-interface/src/components/right-sidebar.tsx#L537-L549).

## Issues
<!-- populated later by plan:check -->

## Steps

### 1. Add `removeRecentDatabasePath` to the API package
File: [packages/api/src/lib/databases-config.ts](packages/api/src/lib/databases-config.ts)

Insert a new exported async function immediately before `markDatabaseOpenedByPath` (around line 224):

```ts
//
// Removes the given path from recentDatabasePaths only. Leaves the matching entry
// in `databases` untouched. No-op if the path is not in the recent list.
//
export async function removeRecentDatabasePath(databasePath: string): Promise<void> {
    const config = await loadDatabasesConfig();
    const filtered = config.recentDatabasePaths.filter(recentPath => recentPath !== databasePath);
    if (filtered.length === config.recentDatabasePaths.length) {
        return;
    }
    config.recentDatabasePaths = filtered;
    await saveDatabasesConfig(config);
}
```

Confirm the function is re-exported by [packages/api/src/index.ts](packages/api/src/index.ts) (it should already barrel-export everything from `databases-config`; if not, add it).

### 2. Expose the function on the Electron API surface
File: [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts)

Inside the `IElectronAPI` interface, add immediately after `getRecentDatabases` (around line 304):

```ts
//
// Removes a path from the recently opened list only; the database entry itself is preserved.
//
removeRecentDatabasePath: (path: string) => Promise<void>;
```

### 3. Add IPC handler in the Electron main process
File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts)

- In the import on line 13, add `removeRecentDatabasePath` to the named imports from `'api'`.
- Immediately after the `'get-recent-databases'` handler (around line 481), add:

```ts
// IPC handler for removing a path from the recently opened database list (does NOT remove the database entry itself).
ipcMain.handle('remove-recent-database-path', logExceptions(async (_event, databasePath: string) => {
    await removeRecentDatabasePath(databasePath);
}, 'Error removing recent database path'));
```

### 4. Add preload bridge
File: [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts)

Immediately after the `getRecentDatabases` bridge (around line 104), add:

```ts
removeRecentDatabasePath: (databasePath: string): Promise<void> => {
    return ipcRenderer.invoke('remove-recent-database-path', databasePath);
},
```

### 5. Add to the platform context interface
File: [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx)

Immediately after `getRecentDatabases` (around line 393), add:

```ts
//
// Removes the given path from the recently opened list only; the underlying database entry is preserved.
//
removeRecentDatabasePath: (path: string) => Promise<void>;
```

### 6. Implement in the Electron platform provider
File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx)

After `getRecentDatabases` (around line 405), add:

```ts
const removeRecentDatabasePath = useCallback(async (databasePath: string): Promise<void> => {
    await electronAPI.removeRecentDatabasePath(databasePath);
}, [electronAPI]);
```

Then add `removeRecentDatabasePath` to the value object returned by the provider (the same place where `getRecentDatabases` is included, around line 493).

### 7. Stub in the web platform provider
File: [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx)

After `getRecentDatabases` (around line 264), add a no-op stub:

```ts
const removeRecentDatabasePath = useCallback(async (_databasePath: string): Promise<void> => {
}, []);
```

Add `removeRecentDatabasePath` to the value object returned by the provider (alongside `getRecentDatabases`, around line 337).

### 8. Add the delete `IconButton` to each recent database in the left sidebar
File: [packages/user-interface/src/components/left-sidebar.tsx](packages/user-interface/src/components/left-sidebar.tsx)

8a. Update the imports on line 10 to include `Delete`:
```ts
import { PhotoLibrary, Folder, FolderOpen, Info, Map, Search, Settings, CreateNewFolder, FileUpload, ManageSearch, Key, Delete } from '@mui/icons-material';
```

8b. Add a new import for `IconButton` (between the existing Joy imports near lines 12-14):
```ts
import IconButton from '@mui/joy/IconButton/IconButton';
```

8c. Replace the recent database `<ListItem>` block (lines 193-211) with a version that adds an `endAction` containing the delete button. The new structure:

```tsx
{recentDatabases.map(dbEntry => (
    <ListItem
        key={dbEntry.path}
        endAction={
            <IconButton
                size="sm"
                variant="plain"
                color="neutral"
                title="Remove from recent databases"
                onClick={async (clickEvent) => {
                    clickEvent.stopPropagation();
                    await platform.removeRecentDatabasePath(dbEntry.path);
                    loadRecentDatabases();
                }}
                sx={{ minHeight: '32px', minWidth: '32px' }}
            >
                <Delete fontSize="small" />
            </IconButton>
        }
    >
        <ListItemButton
            onClick={async () => {
                setSidebarOpen(false);
                await openDatabase(dbEntry.path);
            }}
        >
            <ListItemDecorator>
                {dbEntry.path === databasePath
                    ? <FolderOpen />
                    : <Folder />
                }
            </ListItemDecorator>
            <ListItemContent title={dbEntry.path}>
                {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop() || dbEntry.path}
            </ListItemContent>
        </ListItemButton>
    </ListItem>
))}
```

Notes for the AI executing this step:
- `clickEvent.stopPropagation()` is required so clicking the trash icon does not also trigger `openDatabase` on the parent `ListItemButton`.
- After the API call, call the existing `loadRecentDatabases()` (line 56) to refresh the list. Do not duplicate the function — reuse it.
- Do not touch the active-database highlighting logic. If the user removes the currently open database from recents, the database stays open; only the list entry disappears.

## Unit Tests

File: [packages/api/src/test/lib/databases-config.test.ts](packages/api/src/test/lib/databases-config.test.ts)

Add `removeRecentDatabasePath` to the import list at the top (line 22-24 area) and append a new `describe` block after the `markDatabaseOpenedByPath` block (after line 303):

1. **Removes a path that exists in `recent_database_paths`**
   - `mockReadToml` returns `{ databases: [makeTomlEntry('/a'), makeTomlEntry('/b')], recent_database_paths: ['/a', '/b'] }`.
   - Call `removeRecentDatabasePath('/a')`.
   - Expect `mockWriteToml` called once; assert the written `recent_database_paths` is `['/b']` and `databases` still has both entries.

2. **No-op when the path is not in the recent list**
   - `mockReadToml` returns `{ databases: [makeTomlEntry('/a')], recent_database_paths: [] }`.
   - Call `removeRecentDatabasePath('/a')`.
   - Expect `mockWriteToml` was not called.

3. **Leaves the entry in `databases` untouched**
   - `mockReadToml` returns `{ databases: [makeTomlEntry('/a')], recent_database_paths: ['/a'] }`.
   - Call `removeRecentDatabasePath('/a')`.
   - Assert the written `databases` array still contains the entry for `/a`.

## Smoke Tests

These tests cover the API + IPC layer end-to-end. The UI layer is verified manually (see Human Verification).

File: [apps/cli/test/smoke/](apps/cli/test/smoke/) (or wherever the existing CLI smoke tests live — the AI agent should locate `bun run test:cli` setup and add to that suite if appropriate; otherwise extend an existing TOML round-trip smoke test).

If a TOML-config smoke test already exists, add a case where:
1. A `databases.toml` is seeded with two databases and both paths in `recent_database_paths`.
2. `removeRecentDatabasePath('/path/a')` is invoked through the API barrel.
3. Reload the config and assert `recent_database_paths` equals `['/path/b']` and `databases` is unchanged.

If no such smoke test exists, skip writing one for this layer — the unit tests above cover the API logic and Electron smoke tests don't currently cover the recents list UI.

## Verify

The AI agent must run all of the following from the repo root and confirm each completes without error before reporting success:

1. `bun run compile` — every package and app must compile cleanly.
2. `bun run test` — all unit tests pass, including the three new tests added in `databases-config.test.ts`.
3. `bun run test:cli` — CLI smoke tests pass.
4. `bun run test:electron` — Electron smoke tests pass.
5. `cd packages/api && bun run test -- src/test/lib/databases-config.test.ts` — confirm the new `describe` block executes and all three new cases pass.
6. Grep check: `grep -rn "removeRecentDatabasePath" packages apps` returns the expected references in: `databases-config.ts`, `databases-config.test.ts`, `electron-api.ts`, `preload.ts`, `main.ts`, `platform-context.tsx`, `platform-provider-electron.tsx`, `platform-provider-web.tsx`, `left-sidebar.tsx` — at minimum 9 files.

## Human Verification

After AI execution, a human can confirm correct behaviour by:

1. `bun run dev` to launch the Electron app.
2. Open the left sidebar; expand the "Databases" section. Verify each recent database row now shows a small trash icon on the right side.
3. Hover the trash icon — confirm the tooltip reads "Remove from recent databases".
4. Click the trash icon on a non-active database — confirm:
   - The row disappears immediately from the recents list.
   - The database is **not** opened (i.e. the click did not propagate to the row).
   - On the "Manage Databases" page (`/databases`), the database entry is **still present** (only recents was affected).
5. Click the trash icon on the *currently open* database — confirm:
   - The row disappears from recents.
   - The currently open database stays open (no navigation, no unload).
   - Re-opening that same database via "Open database" or the Manage Databases page re-adds it to recents.
6. Quit and relaunch the app. Verify the removed entry stays absent from recents (persistence via `databases.toml` works).
7. Inspect `~/.config/photosphere/databases.toml` and confirm only `recent_database_paths` was edited; the `[[databases]]` block for the removed path is intact.

## Notes

- **Scope decision**: this plan only edits `recentDatabasePaths`. We deliberately do not delete the database entry, its files, or its secrets — those are managed via the Manage Databases page (`databases-page.tsx:381-389`) which already provides full deletion with a confirmation dialog. Removing from recents is a low-risk, undoable action and does not need a confirmation modal.
- **Why a new function instead of reusing `removeDatabaseEntry`**: `removeDatabaseEntry` deletes the entire `[[databases]]` row, which is destructive. The user explicitly asked to "remove the ones I no longer want in the recent list" — a list-management action, not a deletion. Conflating them would be a footgun.
- **Why mirror `right-sidebar.tsx` instead of `databases-page.tsx`**: the right sidebar's recent-searches pattern is the closest analogue (a sidebar list with a removable item). The databases-page table uses a confirmation dialog appropriate for permanent deletion, which is overkill here.
- **`no-database-loaded.tsx`**: this component also shows recent databases (when no DB is open). It is intentionally **not** modified by this plan — it's a "quick-pick" landing screen, not a management surface. If the user later wants delete buttons there too, that is a separate, follow-up plan.
- **Web platform**: the web (`dev-frontend`) provider stubs `getRecentDatabases` to return `[]`, so the recents section never renders there. The new `removeRecentDatabasePath` is therefore a no-op stub purely to satisfy the `IPlatform` interface contract.
- **`useCallback` dependencies**: in left-sidebar.tsx, `loadRecentDatabases` is currently a plain function defined inside the component body (line 56). It is referenced inside the new `onClick` closure; because the component re-renders after the click triggers a state update, no `useCallback` is needed. Do not refactor `loadRecentDatabases` into `useCallback` as part of this change.
