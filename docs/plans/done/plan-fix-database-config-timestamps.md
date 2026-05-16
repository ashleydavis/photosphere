# Fix Database Config Timestamp Coverage and Consistency

## Overview
The `IDatabaseConfig` interface in [packages/api/src/lib/database-config.ts](packages/api/src/lib/database-config.ts) defines two timestamps with a documented contract:

- `lastModifiedAt` — set when the database is "modified locally (add, remove, edit metadata)".
- `lastSyncedAt` — set when the database is "last synchronized".

The contract is not honored consistently. Two clear gaps and one inconsistency exist:

1. **`applyDatabaseOps`** in [packages/api/src/lib/apply-database-ops.ts](packages/api/src/lib/apply-database-ops.ts) handles `set`/`push`/`pull` metadata operations from the gallery UI (via the `/apply-database-ops` REST endpoint at [packages/rest-api/src/lib/asset-server.ts:215](packages/rest-api/src/lib/asset-server.ts#L215)). It commits to the BSON database but never bumps `lastModifiedAt`. This is the "edit metadata" branch of the contract and the most common local mutation path.
2. **`repair`** in [packages/api/src/lib/repair.ts](packages/api/src/lib/repair.ts) inserts and updates metadata records, then commits, without bumping `lastModifiedAt`. Repair changes content; it is a local modification.
3. **Sync timestamping is inconsistent.** [packages/api/src/lib/sync-database.worker.ts:122-124](packages/api/src/lib/sync-database.worker.ts#L122-L124) stamps `lastSyncedAt` on the local side only; [apps/cli/src/cmd/sync.ts:125-127](apps/cli/src/cmd/sync.ts#L125-L127) stamps both source and target. Both code paths invoke the same bidirectional `syncDatabases` and should agree. The CLI behavior (stamp both) is correct: after a successful bidirectional sync, both databases are equally synchronized.

This plan closes those gaps and makes the worker stamp both sides like the CLI.

**Out of scope:** [apps/bdb-cli/src/cmd/edit.ts](apps/bdb-cli/src/cmd/edit.ts) is a generic BSON record editor and not a Photosphere user surface; the file at [packages/api/src/lib/replicate.ts:611-614](packages/api/src/lib/replicate.ts#L611-L614) sets `origin` and `lastReplicatedAt` for a fresh replica and correctly does not bump `lastModifiedAt`. [apps/cli/src/cmd/set-origin.ts](apps/cli/src/cmd/set-origin.ts) only updates the `origin` field and is not a content modification.

## Issues
<!-- populated later by plan:check -->

## Steps

### 1. Bump `lastModifiedAt` from `applyDatabaseOps`
- File: [packages/api/src/lib/apply-database-ops.ts](packages/api/src/lib/apply-database-ops.ts).
- Add an import: `import { updateDatabaseConfig } from "./database-config";` alongside the existing imports.
- In `applyDatabaseOps`, after the `await database.bsonDatabase.commit();` call inside the `try` block (currently line 90), add:
  ```ts
  await updateDatabaseConfig(rawStorage, { lastModifiedAt: new Date().toISOString() });
  ```
  Place it inside the `try` so the write lock is still held when the config write happens — this matches the existing pattern in `media-file-database.ts` (write merkle tree → update config → release lock in `finally`).
- Only stamp when `pathOps.length > 0`. The current loop body is unconditional, but since `applyDatabaseOps` already early-returns for `ops.length === 0` at the top, and ops are grouped by `databaseId`, every group has at least one op. No extra guard needed; just commit then stamp.

### 2. Bump `lastModifiedAt` from `repair`
- File: [packages/api/src/lib/repair.ts](packages/api/src/lib/repair.ts).
- Change the `repair` function signature at line 100 to accept `rawStorage: IStorage` after `assetStorage`:
  ```ts
  export async function repair(
      assetStorage: IStorage,
      rawStorage: IStorage,
      sourceAssetStorage: IStorage,
      bsonDatabase: IBsonDatabase,
      metadataCollection: IBsonCollection<IAsset>,
      options: IRepairOptions,
      progressCallback?: ProgressCallback
  ): Promise<IRepairResult>
  ```
- Add an import: `import { updateDatabaseConfig } from "./database-config";`.
- After `await bsonDatabase.commit();` at [packages/api/src/lib/repair.ts:311](packages/api/src/lib/repair.ts#L311), add:
  ```ts
  if (result.recordsRepaired.length > 0 || result.repaired.length > 0) {
      await updateDatabaseConfig(rawStorage, { lastModifiedAt: new Date().toISOString() });
  }
  ```
  Stamp only when something actually changed. `recordsRepaired` covers metadata inserts/updates; `repaired` covers file repairs handled earlier in the function. If neither set is non-empty, repair was a no-op verification and should not bump the timestamp.

### 3. Update the sole caller of `repair`
- File: [apps/cli/src/cmd/repair.ts](apps/cli/src/cmd/repair.ts).
- The destructure at line 32 already includes `rawAssetStorage` from `loadDatabase`. Update the `repair(...)` call at line 59 to pass it as the second argument:
  ```ts
  const result = await repair(assetStorage, rawAssetStorage, sourceAssetStorage, bsonDatabase, metadataCollection, { ... }, ...);
  ```

### 4. Make the sync worker stamp both sides
- File: [packages/api/src/lib/sync-database.worker.ts](packages/api/src/lib/sync-database.worker.ts).
- Replace the single `updateDatabaseConfig(localRawStorage, ...)` call at lines 122-124 with two calls — one for each side — using the same timestamp string for both:
  ```ts
  const lastSyncedAt = new Date().toISOString();
  await updateDatabaseConfig(localRawStorage, { lastSyncedAt });
  await updateDatabaseConfig(originRawStorage, { lastSyncedAt });
  ```
- This matches the CLI behavior at [apps/cli/src/cmd/sync.ts:125-127](apps/cli/src/cmd/sync.ts#L125-L127) and ensures both databases agree on when they were last synchronized.

### 5. Update existing tests broken by the `repair` signature change
- File: search for all `repair(` invocations under `packages/api/src/test/` and `apps/cli/`. Use `grep -rn "repair(" packages/api/src/test/ apps/cli/src/` to find them.
- Insert `rawStorage` as the second argument in every test call site. For tests that construct storage with `createStorage(...)`, both `storage` and `rawStorage` are returned together, so the wiring is mechanical.

## Unit Tests

### `apply-database-ops.test.ts`
- File: [packages/api/src/test/lib/apply-database-ops.test.ts](packages/api/src/test/lib/apply-database-ops.test.ts).
- Extend the existing `describe("applyDatabaseOps")` block (the test at line 220 already creates a real on-disk database).
- Add a new test:
  - **`stamps lastModifiedAt on the database config after applying ops`** — call `applyDatabaseOps` against a real temp directory, then `loadDatabaseConfig(rawStorage)` and assert `config.lastModifiedAt` is a valid ISO date string. Capture a `before` timestamp around the call and assert `before <= config.lastModifiedAt <= after`.
  - **`writes config separately for each database group`** — call `applyDatabaseOps` with ops targeting two different temp database paths; assert each path's config has its own `lastModifiedAt` value.

### `repair.test.ts` (new file)
- File: `packages/api/src/test/lib/repair.test.ts`.
- The `repair` function currently has no unit tests. Add a minimal test file that constructs a real on-disk database via `createStorage` + `createDatabase`, then exercises:
  - **`bumps lastModifiedAt when records are repaired`** — seed a merkle tree with an asset node whose hash does not match a metadata record, call `repair`, assert `config.lastModifiedAt` was set.
  - **`does not bump lastModifiedAt when no repairs were needed`** — call `repair` against a healthy database (no asset/metadata mismatches, no file repairs), assert `config.lastModifiedAt` is `undefined` (or unchanged from before).
- Use the same fixture-construction style as [packages/api/src/test/lib/apply-database-ops.test.ts](packages/api/src/test/lib/apply-database-ops.test.ts) (real `createStorage` + temp dir + `MockTimestampProvider`).

### `sync-database.worker.test.ts` (new or extended)
- Search `packages/api/src/test/` for any existing `sync-database.worker` test file. If none, create `packages/api/src/test/lib/sync-database.worker.test.ts`.
- Mock `./sync` so `syncDatabases` is a no-op resolving to `undefined`, and mock `./database-config` so `updateDatabaseConfig` is a `jest.fn()` (matching the pattern in [packages/api/src/test/lib/import-assets.worker.test.ts:74-76](packages/api/src/test/lib/import-assets.worker.test.ts#L74-L76)).
- Mock `loadDatabaseConfig` to return `{ origin: "/fake/origin" }` and `checkConnectivity` to return `true` so the handler proceeds past the early returns.
- Add a test:
  - **`stamps lastSyncedAt on both local and origin storage with the same value`** — invoke `syncDatabaseHandler`, then assert `updateDatabaseConfig` was called twice (once per raw storage) and the `{ lastSyncedAt: ... }` value was identical between calls.

## Smoke Tests

Add a new CLI smoke test directory: `apps/cli/smoke-tests/64-config-timestamps/test.sh`. Follow the conventions in [apps/cli/smoke-tests/43-replicate-partial/test.sh](apps/cli/smoke-tests/43-replicate-partial/test.sh) (sources `lib/common.sh`, uses `invoke_command`, `expect_value`, etc.). Cover:

1. **`add` bumps `lastModifiedAt`** — init a database, add a file, parse `.db/config.json`, assert `lastModifiedAt` is present and is a valid ISO date.
2. **`sync` stamps both sides with the same `lastSyncedAt`** — set up two databases (set one as origin of the other via `psi set-origin`), run `psi sync`, parse `.db/config.json` from both, assert `lastSyncedAt` is present in both and the values are equal.
3. **`repair` bumps `lastModifiedAt` when records need repair** — start with a database, corrupt a metadata record's hash (or remove it) so `repair` has work to do, run `psi repair`, parse the post-run config, assert `lastModifiedAt` advanced past the pre-run value.

Use `jq` to parse `.db/config.json`; if `jq` is not already a smoke-test dependency, fall back to `grep`/`sed` to extract the field.

## Verify
1. `bun run compile` from repo root — TypeScript compiles cleanly across all packages.
2. `bun run test` from repo root — full unit test suite passes.
3. `bun run test:cli` from repo root — CLI smoke tests pass, including the new `64-config-timestamps`.
4. `bun run test:electron` from repo root — Electron smoke tests pass (the worker change is exercised here).

## Human Verification
1. Open the desktop app on an existing database. Edit a photo's labels or description in the gallery. Inspect `.db/config.json` in the database directory and confirm `lastModifiedAt` updated to the time of the edit.
2. Configure a database with an `origin` (via `psi set-origin`) and trigger a background sync from the desktop app. After sync completes, inspect `.db/config.json` on both the local and origin databases and confirm `lastSyncedAt` is present in both with matching values.
3. Run `psi repair --db <some-db>` against a database with no integrity issues; confirm `lastModifiedAt` does **not** change in `.db/config.json`. Then deliberately corrupt a metadata record (e.g. via `psi-bdb edit`), re-run `psi repair`, and confirm `lastModifiedAt` advances.

## Notes
- **Why timestamp the origin from the worker?** The bidirectional `syncDatabases` call writes to both sides (push half writes the origin's merkle tree, deletes target files, deletes metadata). After the call returns successfully, both databases are at a synchronized state, so both deserve `lastSyncedAt`. This also matches the CLI's behavior, which the user has identified as the correct one.
- **Why not bump `lastModifiedAt` on the sync push target?** Sync changes are not "modified locally" — they are coordinated bidirectional reconciliation. The interface comment scopes `lastModifiedAt` to local actions (add, remove, edit metadata). `lastSyncedAt` is the appropriate signal for sync, on both sides.
- **`bdb-cli edit` left intentionally untouched.** It is a generic BSON record editor under `apps/bdb-cli/`, not a Photosphere-aware tool. Adding `updateDatabaseConfig` there would couple a generic utility to Photosphere's database semantics.
- **`repair` signature change is a breaking change for any external caller**, but `grep` shows the only caller is [apps/cli/src/cmd/repair.ts:59](apps/cli/src/cmd/repair.ts#L59). No backwards-compatibility shim needed (CLAUDE.md: "Backward compatibility is not required").
- **Stamping condition in `repair`.** Using `result.recordsRepaired.length > 0 || result.repaired.length > 0` covers both the metadata-side fixes (lines 288, 299 in repair.ts) and the file-side repairs handled earlier. Healthy databases stay untimestamped, which prevents `lastModifiedAt` from advancing on every routine `psi verify` run that happens to invoke repair internally — verify the CLI repair flow does not run on every verify call.
