# Plan: Remove database entry UUID, use path as identifier

## Context

The `IDatabaseEntry.id` (8-char UUID) is an unnecessary indirection. The path is already the natural identifier — it's what storage, the REST API, and the worker pool consume. Every operation that uses the UUID immediately resolves it back to a path. Removing it simplifies the codebase and makes `lastDatabase` work naturally for all database types.

Note: `ISharedSecretEntry.id`, `s3CredentialId`, `encryptionKeyId`, `geocodingKeyId` are **unrelated** — these reference shared secrets in the vault and are not touched by this change.

---

## Changes

### 1. `packages/electron-defs/src/lib/electron-api.ts`
- Remove `id` field from `IDatabaseEntry` interface (line 77)
- Update `addDatabase` signature: remove `Omit<IDatabaseEntry, 'id'>`, just use `IDatabaseEntry` (line 256)
- Change `removeDatabaseEntry(id: string)` to `removeDatabaseEntry(path: string)` (line 266)

### 2. `packages/user-interface/src/context/platform-context.tsx`
- Mirror the same `IDatabaseEntry` changes: remove `id` field (line 70)
- Update `addDatabase` signature: `IDatabaseEntry` instead of `Omit<IDatabaseEntry, 'id'>` (line 345)
- Change `removeDatabaseEntry(id: string)` to `removeDatabaseEntry(path: string)` (line 355)

### 3. `packages/node-utils/src/lib/databases-config.ts`
- Rename `recentDatabaseIds` to `recentDatabasePaths` in `IDatabasesConfig` (line 18), and update all references (lines 30, 37, 52, 98, 117-120)
- `updateDatabaseEntry`: match by `path` instead of `id` (line 78)
- `removeDatabaseEntry`: take `path: string`, filter by `path` instead of `id` (lines 85-88)
- `getRecentDatabases`: iterate `recentDatabasePaths`, find by `path` (lines 98-99)
- `markDatabaseOpenedByPath`: store `found.path` in `recentDatabasePaths` instead of `found.id` (lines 117-119)
- Handle backward compat on load: if old `recentDatabaseIds` field exists, ignore it (it will be dropped on next save)

### 4. `apps/desktop/src/main.ts`
- Remove `generateDatabaseId()` function (lines 59-64)
- `add-database` handler (line 295): remove `id: generateDatabaseId()` from `newEntry`, accept `IDatabaseEntry` instead of `Omit<IDatabaseEntry, 'id'>`
- `remove-database-entry` handler (line 238): parameter is now a path string
- `get-database-secrets` handler (line 315): find by `path` instead of `id` — change `entry.id === id` to `entry.path === path`
- `notify-database-opened` handler (line 362): remove `id: generateDatabaseId()` from `newEntry` creation (line 370)

### 5. `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`
- Update `addDatabase` callback: pass full `IDatabaseEntry` instead of `Omit<IDatabaseEntry, 'id'>`
- Update `removeDatabaseEntry` callback: pass path instead of id

### 6. `apps/dev-frontend/src/lib/platform-provider-web.tsx`
- Same signature changes as electron provider

### 7. Frontend components — update React `key` props and callers
All `key={dbEntry.id}` or `key={entry.id}` become `key={dbEntry.path}` or `key={entry.path}`:
- `packages/user-interface/src/components/left-sidebar.tsx` (line 192)
- `packages/user-interface/src/components/open-database-modal.tsx` (line 95)
- `packages/user-interface/src/components/right-sidebar.tsx` (line 373)
- `packages/user-interface/src/components/no-database-loaded.tsx` (line 78)
- `packages/user-interface/src/pages/databases/databases-page.tsx` (line 304)

### 8. `packages/user-interface/src/pages/databases/databases-page.tsx`
- `removeDatabaseEntry(removingEntry.id)` → `removeDatabaseEntry(removingEntry.path)` (line 185)
- `updateDatabase({ ...editingEntry, ...entryData })` — no change needed (still spreads full entry)

### 9. `packages/user-interface/src/context/app-context.tsx`
- `removeDatabaseEntry(id)` → `removeDatabaseEntry(path)` (line 49) — check what calls this

### 10. `packages/user-interface/src/components/add-database-modal.tsx` and `create-database-modal.tsx`
- `platform.addDatabase({...})` — no longer needs `Omit`, just passes a full `IDatabaseEntry`

### 11. `apps/desktop/src/preload.ts`
- Check if the IPC channel signatures need updating for `add-database` and `remove-database-entry`

---

## Verification

1. `bun run compile` — TypeScript must compile clean
2. `bun run test` — all tests pass
3. Manual test: open the desktop app, add/open/remove databases, verify recent databases list works correctly
