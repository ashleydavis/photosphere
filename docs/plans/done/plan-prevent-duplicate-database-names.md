# Plan: Make Name the Canonical Database Identifier (and Prevent Duplicates)

## Overview

Receiving a database in the Electron app currently does not check whether an entry already exists with the same name. The user ends up with duplicate-name entries; clicking delete on the duplicate "deletes every database with that name," wiping out their configuration. The root cause is that the storage layer keys entries by path (with no name uniqueness check) while users think of databases by name. This plan reorients the data model so **name is the canonical, case-insensitive-unique identifier** for a database entry, and updates every code path that adds, removes, renames, or marks a database as recently opened to follow that model.

Concrete shifts:
- `databases` array is identified by **name** (case-insensitive unique invariant enforced at the storage layer).
- `recentDatabasePaths` is renamed to `recentDatabaseNames` and stores names. This is needed because for encrypted/S3 databases the recents entry isn't useful on its own — the system has to look up the full entry (S3 creds reference, encryption key reference) every open, so the recents key should be the unique identifier.
- Renaming an entry updates the recents list; removing an entry cleans the recents list.
- The receive dialog gets a `db-name-conflict` modal step (Replace / Rename / Cancel); create-database and add-database modals show inline name-conflict errors.
- `removeDatabaseEntry` is hardened so even if legacy duplicate state exists it won't mass-delete.

**Root cause references:**
- `addDatabaseEntry` blindly appends — no uniqueness check: [packages/api/src/lib/databases-config.ts:181-185](../../../packages/api/src/lib/databases-config.ts#L181-L185)
- Electron receive flow appends without a check: [apps/desktop/src/main.ts:657-662](../../../apps/desktop/src/main.ts#L657-L662)
- CLI receive flow appends without a check: [apps/cli/src/cmd/dbs.ts:1418-1419](../../../apps/cli/src/cmd/dbs.ts#L1418-L1419)
- `removeDatabaseEntry` filters by path (removes ALL same-path matches): [packages/api/src/lib/databases-config.ts:199-203](../../../packages/api/src/lib/databases-config.ts#L199-L203)
- React table key is `entry.path` so same-path duplicates render as one row: [packages/user-interface/src/pages/databases/databases-page.tsx:341](../../../packages/user-interface/src/pages/databases/databases-page.tsx#L341)
- Existing pattern to mirror — CLI `dbs add` name check: [apps/cli/src/cmd/dbs.ts:128-138](../../../apps/cli/src/cmd/dbs.ts#L128-L138) and [apps/cli/src/cmd/dbs.ts:501-506](../../../apps/cli/src/cmd/dbs.ts#L501-L506)
- Existing pattern to mirror — vault-secret conflict modal step: [packages/user-interface/src/components/receive-database-dialog.tsx:347-381](../../../packages/user-interface/src/components/receive-database-dialog.tsx#L347-L381)

## Steps

### 1. Storage-layer changes in the api package

In [packages/api/src/lib/databases-config.ts](../../../packages/api/src/lib/databases-config.ts):

- **Add `findDatabaseEntryByName(name: string): Promise<IDatabaseEntry | undefined>`** — case-insensitive lookup. Refactor the CLI's private `findDatabaseByName` at [apps/cli/src/cmd/dbs.ts:128-138](../../../apps/cli/src/cmd/dbs.ts#L128-L138) to import this so there is one source of truth.
- **Schema rename:** on-disk `recent_database_paths` → `recent_database_names`; in-memory `recentDatabasePaths` → `recentDatabaseNames`. Update `ITomlDatabasesConfig` and `IDatabasesConfig`.
- **Migration on load:** in `loadDatabasesConfig`, if the loaded TOML has the legacy `recent_database_paths` field, convert each path → name by looking it up in `databases`; drop entries whose path no longer matches any database. Save the migrated config back to disk so subsequent loads use the new field. Mirrors the existing `databases.json` → `databases.toml` migration at [packages/api/src/lib/databases-config.ts:138-155](../../../packages/api/src/lib/databases-config.ts#L138-L155).
- **`addDatabaseEntry(entry)` backstop:** before appending, check for a case-insensitive name collision; throw `DuplicateDatabaseNameError` if one exists. UI/CLI flows validate first; this throw guarantees the on-disk invariant.
- **`updateDatabaseEntry(originalName, entry)`:** change signature from path-matching to taking an explicit `originalName`. If `entry.name !== originalName`, also rewrite the matching slot in `recentDatabaseNames`. If the new name collides with another existing entry, throw `DuplicateDatabaseNameError`.
- **`removeDatabaseEntry(name)`:** change signature from path to name. Find the entry by case-insensitive name match, splice the first match from `databases`, and remove the same name from `recentDatabaseNames`. Single call cleans both arrays.
- **`markDatabaseOpened(name)`** (rename from `markDatabaseOpenedByPath`): look up entry by name; if found, move its name to the front of `recentDatabaseNames`, trim to 5.
- **`removeRecentDatabaseName(name)`** (rename from `removeRecentDatabasePath`): pure recents-list operation for the trash-from-recents button (recent commit `9d5becf0`).
- **`getRecentDatabases()`:** iterate `recentDatabaseNames`, look up each via `findDatabaseEntryByName`, drop missing.

### 2. Receive dialog (Electron) — `db-name-conflict` step

In [packages/user-interface/src/components/receive-database-dialog.tsx](../../../packages/user-interface/src/components/receive-database-dialog.tsx):

- Extend the existing `detectConflicts` (line 146) to also check for an existing database with the same `editedName` via a new platform method (see step 4).
- If a name conflict exists, route to a new step `"db-name-conflict"` (parallel to the existing vault-secret `"conflict"` step). Show three options:
  - **Replace existing** — on Continue: call `removeDatabaseEntry(existingName)` first, then proceed with import.
  - **Rename** — input a new name, validate it is also unique, then proceed with import using the new name.
  - **Cancel** — return to the review step so the user can change name/description/path or abandon.
- Vault-secret conflict step still runs first if present; the database-name conflict step runs after secrets are resolved (or in place of, if no secret conflicts).

### 3. Create-database and add-database modals (Electron) — inline name-conflict error

In [packages/user-interface/src/components/create-database-modal.tsx](../../../packages/user-interface/src/components/create-database-modal.tsx) and [packages/user-interface/src/components/add-database-modal.tsx](../../../packages/user-interface/src/components/add-database-modal.tsx):

- Before submitting, call `findDatabaseByName`. If a match exists, show inline error helper text under the Name field and disable the submit button until the user changes the name.

### 4. Wire platform methods through Electron and web

- Add `findDatabaseByName(name: string): Promise<IDatabaseEntry | undefined>` to:
  - Interface: [packages/user-interface/src/context/platform-context.tsx](../../../packages/user-interface/src/context/platform-context.tsx)
  - Electron impl: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](../../../apps/desktop-frontend/src/lib/platform-provider-electron.tsx) — forwards to a new IPC method
  - Web impl: [apps/dev-frontend/src/lib/platform-provider-web.tsx](../../../apps/dev-frontend/src/lib/platform-provider-web.tsx) — filter the existing `getDatabases` response client-side (no new dev-server endpoint)
  - IPC handler `find-database-by-name` in [apps/desktop/src/main.ts](../../../apps/desktop/src/main.ts)
  - Preload typing in [packages/electron-defs/src/lib/electron-api.ts](../../../packages/electron-defs/src/lib/electron-api.ts)
- Update existing platform/IPC signatures to match the new api:
  - `removeDatabaseEntry(path)` → `removeDatabaseEntry(name)` — every call site.
  - `updateDatabaseEntry(entry)` → `updateDatabaseEntry(originalName, entry)`.
  - `markDatabaseOpenedByPath(path)` → `markDatabaseOpened(name)`.
  - `removeRecentDatabasePath(path)` → `removeRecentDatabaseName(name)`.

### 5. Update UI call sites for the new signatures

- [packages/user-interface/src/pages/databases/databases-page.tsx](../../../packages/user-interface/src/pages/databases/databases-page.tsx): the delete handler at line 204 passes `removingEntry.name` instead of `.path`. The recents-card trash button calls `removeRecentDatabaseName(entry.name)`.
- [packages/user-interface/src/components/view-database-dialog.tsx](../../../packages/user-interface/src/components/view-database-dialog.tsx): pass the entry's pre-edit name as `originalName` to `updateDatabaseEntry`. Treat a rename to a colliding name as a validation error.

### 6. CLI changes

In [apps/cli/src/cmd/dbs.ts](../../../apps/cli/src/cmd/dbs.ts):

- Refactor private `findDatabaseByName` to import the api helper.
- `receive` command (around line 1418): after the user finalizes name/path, call `findDatabaseEntryByName(payload.name)`.
  - Interactive: clack `select` prompt with Replace / Rename / Cancel mirroring the GUI. Replace → `removeDatabaseEntry(existing.name)` first. Rename → re-prompt for a unique name, looping until unique or cancel. Cancel → `outro(pc.yellow('Cancelled.'))` and return.
  - `--skip-prompts`: error out as the existing CLI `add` does at lines 501-506.
- Audit other CLI commands that call `removeDatabaseEntry` / `updateDatabaseEntry` / `markDatabaseOpenedByPath` for the new signatures.

## Unit Tests

Add to [packages/api/src/test/lib/databases-config.test.ts](../../../packages/api/src/test/lib/databases-config.test.ts):

- `findDatabaseEntryByName` — undefined on no match; returns entry on case-insensitive match.
- `addDatabaseEntry` — throws `DuplicateDatabaseNameError` on case-insensitive collision; succeeds otherwise.
- `updateDatabaseEntry` — when the name changes, the corresponding `recentDatabaseNames` slot is updated; throws on collision with another existing entry; works when the name is unchanged.
- `removeDatabaseEntry` — removes the entry AND removes the name from recents; idempotent if the name doesn't exist.
- `markDatabaseOpened` — moves the name to the front of recents, trims to 5.
- `loadDatabasesConfig` migration — given a TOML with `recent_database_paths`, converts to `recent_database_names` using the entries list; drops paths that don't resolve; writes the migrated form back to disk.

Update CLI test mocks in [apps/cli/src/test/cmd/dbs.test.ts](../../../apps/cli/src/test/cmd/dbs.test.ts) and [apps/cli/src/test/cmd/secrets.test.ts](../../../apps/cli/src/test/cmd/secrets.test.ts) for the renamed exports.

## Smoke Tests

- **CLI** (`apps/cli/smoke-tests/`):
  - Receive with a colliding name: Replace, Rename, Cancel branches.
  - `--skip-prompts` rejection on duplicate name.
  - Rename a database via CLI → verify recents list reflects the new name.
- **Electron** ([apps/desktop/smoke-tests/8-share-database/](../../../apps/desktop/smoke-tests/8-share-database/)):
  - Receive dialog drives through the `db-name-conflict` step (Replace / Rename branches), assert resulting `databases.toml`.

## Verify

1. `bun run compile` from the repo root.
2. `bun run test` — unit tests pass.
3. `bun run test:cli` — CLI smoke tests pass.
4. `bun run test:electron` — Electron smoke tests pass.
5. **Migration sanity check:** copy an existing `~/.config/photosphere/databases.toml` with the old `recent_database_paths` field. After `bun run dev`, confirm it has been rewritten with `recent_database_names` populated, with names looked up from the entries.
6. **Manual end-to-end test in Electron** (`bun run dev`):
   - Create a database "MyPhotos" at `/tmp/a`.
   - Receive a share with name "MyPhotos" → confirm the `db-name-conflict` step appears.
     - Replace: only one "MyPhotos" remains afterwards.
     - Rename to a unique name: both coexist.
     - Cancel: returns to review, nothing saved.
   - Try New database with name "MyPhotos" → inline error, Save disabled.
   - Try Add database with name "MyPhotos" → inline error, Save disabled.
   - Open "MyPhotos" → it appears in recents. Rename it to "Vacation" → recents now shows "Vacation". Delete it → recents no longer lists it.
   - With one entry left, click delete → only that entry is removed (regression test).
7. **Manual CLI test:** `psi receive` with a colliding name → Replace/Rename/Cancel prompt; `--skip-prompts` mode → hard error.

## Notes

- **Why name as the canonical identifier:** name is the user-facing concept. The user clicks "delete" on a row labelled "MyPhotos" — the natural identifier is the name they read, not the path. Aligning storage with the user's mental model removes a class of edge cases (same-path duplicates rendering as one row, mass-delete on path removal).
- **Why recents stores names too:** for encrypted/S3 databases the recents entry isn't useful on its own — the system has to look up the full entry every open. Keying recents by name keeps a single canonical identifier across the whole config.
- **Names are mutable** (the rename UI can change them), so two new write paths must keep things consistent: `updateDatabaseEntry` must rewrite the matching `recentDatabaseNames` slot on rename; `removeDatabaseEntry` must clean recents on delete. Both are covered above.
- **Storage-layer backstop in `addDatabaseEntry`:** treating no-duplicate-names as an invariant (not just a UX policy) prevents future regressions from any new code path that adds entries. Cost is one extra read of the config before each write — acceptable for a config file of <100 entries.
- **Replace semantics:** "Replace" deletes the existing entry (by its name) then adds the new one. It does not delete the on-disk database files, only the entry in `databases.toml`.
- **Case-insensitive matching:** mirrors the existing CLI behaviour at [apps/cli/src/cmd/dbs.ts:128-138](../../../apps/cli/src/cmd/dbs.ts#L128-L138). Treating "MyPhotos" and "myphotos" as distinct would surprise users.
- **Migration is one-shot:** the legacy `recent_database_paths` field is read once on load, converted, and the file rewritten with `recent_database_names`. No need to keep both fields.
- **Open question:** behaviour of `findDatabaseEntryByName` if multiple matches exist on disk (legacy state from before the invariant). Recommend: return the first match (so callers handle gracefully); a separate one-time cleanup pass on `loadDatabasesConfig` could optionally log a warning. Defer until needed.
