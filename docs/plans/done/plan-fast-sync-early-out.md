# Plan: Fast early-out for database sync

## Goal

Make a sync between a local database and its remote origin return almost instantly when there are no differences, instead of doing several remote round-trips and full merkle-tree downloads every time.

## Problem

`syncDatabases` (`packages/node-api/src/lib/sync.ts:15`) does all of the following before it can even conclude "nothing changed", for both directions (pull then push):

- Acquires a write lock on the remote (`sync.ts:31`, `sync.ts:53`), a network write plus release round-trip each way, with retry/backoff. Already flagged in code: `//todo: Don't need write lock if nothing to pull.`
- Downloads and fully deserializes the remote merkle trees (`.db/files.dat` and the `.db/bson` trees), then rebuilds them in memory just to read their root hash. The files tree is loaded twice per direction.
- Rewrites `.db/config.json` on both local and remote to stamp `lastSyncedAt` (`sync-database.worker.ts:121`).

The root-hash comparison that proves "identical, nothing to do" (`sync.ts:118`, `sync.ts:525`) only runs after all that work. There is no cheap up-front check.

## Approach

Store a small, checksummed binary state file per database that records the database's current content hash (the combined merkle root). At the start of a sync, read only that tiny file from both sides and compare the content hashes. If they are equal, the databases are identical, so return immediately with no lock, no tree download, and no remote write.

The same file also holds the runtime timestamps that currently live in `config.json` but are not really configuration (`lastModifiedAt`, `lastSyncedAt`, `lastReplicatedAt`). `origin` stays in `config.json` because it is genuine configuration.

## New file: `.db/state.dat`

- Location: `.db/state.dat`, alongside the existing `.db/files.dat` and `.db/config.json`.
- Serialized with the existing `serialization` library (`packages/serialization/src/lib/serialization.ts`) using `save`/`load`, which already writes the `[version 4][type 4][payload][checksum 32]` layout and verifies the sha256 checksum on load.
- Type code: `DBST`. Version: `1` (own version line, independent of the merkle-tree `CURRENT_DATABASE_VERSION`).
- Rebuildable and disposable: if the file is missing, zero bytes, too small, or fails its checksum, it is treated as absent and rebuilt from the current trees on the next write. It is never the source of truth for content; the merkle trees are. Losing it only costs one full sync.

### Payload fields (`IDatabaseState`)

- `contentHash?: Buffer` — 32 bytes, the combined merkle root: `combineHashes(filesRootHash, bsonDbRootHash)`. Present only when both trees exist. This is the value compared for the early-out.
- `lastModifiedAt?: string` — ISO date-time, moved from `config.json`.
- `lastSyncedAt?: string` — ISO date-time, moved from `config.json`.
- `lastReplicatedAt?: string` — ISO date-time, moved from `config.json`.

Fields are written with the serializer primitives (`writeBuffer` for the hash, `writeString` for timestamps, empty string meaning absent). New fields can be appended in a later version if ever needed; no extensibility scaffolding is added now.

## New module: `packages/api/src/lib/database-state.ts`

Sits next to `database-config.ts`, same style and layering (storage plus serialization only, no knowledge of trees).

- `interface IDatabaseState` — the fields above, each with a `//` comment.
- `loadDatabaseState(rawStorage): Promise<IDatabaseState | undefined>` — reads `.db/state.dat` via the serialization `load`. Returns `undefined` if the file is missing, empty, too small, or corrupt (catch the checksum/parse error and return `undefined` so callers rebuild). Never throws for a bad file.
- `saveDatabaseState(rawStorage, state): Promise<void>` — lock-free primitive that serializes and writes the whole state via `save`. The caller must already hold the write lock. Documented in the function comment.
- `updateDatabaseStateLocked(rawStorage, sessionId, partial): Promise<void>` — for callers that do not already hold the lock: acquires the write lock, loads (or starts from `{}` if absent), merges the partial, saves, releases in a `finally`. Returns without writing if the lock cannot be acquired (same pattern as the existing sync/lock code).

Add `serialization` to `packages/api/package.json` dependencies (currently pulled in only transitively via `merkle-tree`).

## Content-hash helper: `packages/node-api/src/lib/tree.ts`

Content-hash computation needs the tree loaders, which live in `node-api`/`bdb`, so it belongs here, not in `api`.

- `getDatabaseContentHash(assetStorage): Promise<Buffer | undefined>` — loads the files root (`getFilesRootHash`, `tree.ts:65`) and the bson db root (`getDatabaseRootHash`, `bdb/merkle-tree.ts:320`) and returns `combineHashes(filesRoot, bsonRoot)` (exported from `merkle-tree`). Returns `undefined` if either root is unavailable. On the local side the trees are on local disk, so this is cheap.

## Write-lock rule and crash safety

The state file is a database write, so every write to it happens under the write lock, per the two entry points above.

- Sites that already hold the lock (`media-file-database.ts:410,474,603`, `apply-database-ops.ts:92`, `import-assets.worker.ts:155`, `repair.ts:316`) call the lock-free `saveDatabaseState` inside their existing locked region. They already have the in-memory merkle tree, so they compute `contentHash` via `getDatabaseContentHash` and write it together with the new `lastModifiedAt`.
- Sites that do not hold the lock (`sync-database.worker.ts:121`, `cli/sync.ts:127`, `replicate.ts:612`) use `updateDatabaseStateLocked`.

Correctness rule to avoid a false "identical" result: within a locked mutation, write the state file (with the new `contentHash`) before persisting the changed merkle tree, or accept that a crash between the two leaves `contentHash` stale-old. Writing state first means a crash leaves `contentHash` ahead of the on-disk tree, which produces a harmless false mismatch (one extra full sync that self-heals the file), never a false match (a skipped real change). This ordering is the one correctness requirement of the whole feature.

## Early-out in `syncDatabases` (`packages/node-api/src/lib/sync.ts`)

At the very top of `syncDatabases`, before any lock or tree load:

- `const localState = await loadDatabaseState(sourceRawStorage);`
- `const remoteState = await loadDatabaseState(targetRawStorage);` (one small remote read)
- If both have a `contentHash` and `localState.contentHash.equals(remoteState.contentHash)`, the databases are identical. Return a result indicating nothing was synced and do no locks, tree loads, or remote writes.
- Otherwise fall through to the existing full sync unchanged. Missing or mismatched hashes always degrade to today's behaviour.

`syncDatabases` returns a small result (for example `{ synced: boolean }`) so callers know whether anything happened.

Callers on the no-change path:

- `sync-database.worker.ts`: when `synced` is false, skip both `updateDatabaseConfig(..., lastSyncedAt)` calls. Optionally stamp `lastSyncedAt` on the local state only via `updateDatabaseStateLocked(localRawStorage, ...)` (fast, local, no remote write) so the UI can still show a last-checked time. No remote interaction beyond the single state read.
- `cli/sync.ts`: same, skip the remote `lastSyncedAt` write on the no-change path.

## Migration: move timestamps out of `config.json`

- Remove `lastReplicatedAt`, `lastSyncedAt`, `lastModifiedAt` from `IDatabaseConfig` (`packages/api/src/lib/database-config.ts`). Keep `origin`.
- Repoint every writer listed above from `updateDatabaseConfig({ ... })` to the state-file writers.
- `replicate.ts:612` currently writes `origin` and `lastReplicatedAt` together: keep the `origin` write in `config.json`, move `lastReplicatedAt` to the state file.
- Audit for readers of these three fields (info/summary/status commands, UI, any display) with a repo-wide search and repoint them to `loadDatabaseState`. The `config.origin` readers (`media-file-database.ts:632`, `sync-database.worker.ts:35`, `cli/sync.ts:44`) are unaffected.
- Update the CLI smoke test `apps/cli/smoke-tests/64-config-timestamps` to read the timestamps from `.db/state.dat` instead of `config.json`.

## Tests

Unit tests (under each package's `src/test`):

- `database-state`: round-trip save then load returns the same fields; load of a missing file returns `undefined`; load of a zero-byte file returns `undefined`; load of a truncated/corrupted file (flipped byte, bad checksum) returns `undefined`; `updateDatabaseStateLocked` merges into an existing file and creates one when absent; a write fails cleanly when the lock is held by another owner.
- `getDatabaseContentHash`: returns a stable value for a fixed database, changes after a mutation, and is `undefined` when a tree is missing.
- `syncDatabases` early-out: with equal `contentHash` on both sides it returns `{ synced: false }` and performs no write-lock acquire and no tree load (assert against a mock storage that records calls); with differing or absent hashes it runs the full sync.

Smoke tests:

- Add a CLI smoke test: create a database, sync to a remote, then sync again with no changes and assert the second sync does no remote lock or tree download (for example by asserting it is fast and/or by inspecting mock/again-idempotent output), and that a real change on either side still syncs.
- Update smoke test `64-config-timestamps` as noted above.

## Out of scope (keep it simple)

- No per-collection or per-shard early-out. The whole-database content hash is enough.
- No new config knobs, no schema versioning beyond the single `version = 1`.
- No change to the merkle-tree file formats.

## Files touched

- New: `packages/api/src/lib/database-state.ts`, its test, and export from `packages/api/src/index.ts`.
- `packages/api/package.json` (add `serialization` dependency).
- `packages/api/src/lib/database-config.ts` (remove the three timestamp fields).
- `packages/node-api/src/lib/tree.ts` (add `getDatabaseContentHash`).
- `packages/node-api/src/lib/sync.ts` (early-out, return value).
- `packages/node-api/src/lib/sync-database.worker.ts`, `apps/cli/src/cmd/sync.ts` (no-change path, timestamp writes).
- `packages/node-api/src/lib/media-file-database.ts`, `apply-database-ops.ts`, `import-assets.worker.ts`, `repair.ts`, `replicate.ts` (repoint timestamp writes to the state file).
- `apps/cli/smoke-tests/64-config-timestamps` and a new sync early-out smoke test.
