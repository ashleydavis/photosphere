# Record the database mode (full or partial) in `.db/config.json`

## Overview

Today nothing on disk plainly says whether a database is a full copy or a partial replica. The flag lives as `isPartial?: boolean` inside `IDatabaseMetadata`, which is embedded in the files merkle tree and serialised as BSON into `.db/files.dat`. To answer "is this database partial?" you must load and parse the entire merkle tree (`isDatabasePartial` in `packages/node-api/src/lib/media-file-database.ts` does exactly that, and callers pay for it on every asset load). Nothing a person can open and read tells them what they are looking at, and the two facts that define a partial replica are split across two files: `origin` lives in `.db/config.json` while `isPartial` lives in the merkle tree. This plan moves the flag into `.db/config.json` as an explicit `mode` field with the values `"full"` and `"partial"`, makes that file the single source of truth, and surfaces the mode in the CLI summary and the view-database dialog. Reading the mode becomes a small JSON read next to the `origin` it belongs with, and opening `.db/config.json` in any text editor answers the question immediately.

## Issues

## Steps

Each step must leave `bun run compile` clean and `bun run test` passing before it is considered done.

### Step 1: Add `mode` to the on-disk database config

In `packages/api/src/lib/database-config.ts`:

- Add an exported string-union type `DatabaseMode` with the values `"full"` and `"partial"`, with a comment block explaining that `"partial"` means only the `thumb` directory's assets are present locally and the rest are fetched lazily from `origin`.
- Add a required `mode: DatabaseMode` field to `IDatabaseConfig`, with a field comment.
- Add an exported function `readDatabaseMode(rawStorage: IStorage): Promise<DatabaseMode>` that loads the config and returns its `mode`, defaulting to `"full"` when the config file is absent or the field is missing. Every caller wants this defaulting, and putting it in one place stops each call site inventing its own.
- Update the file header comment to say the config now holds `origin` and `mode`.

`updateDatabaseConfig` keeps its read-merge-write behaviour and needs no signature change. Note that `saveDatabaseConfig` callers must now pass a `mode`, so this step will produce type errors at the call sites fixed in steps 2 and 3. Fix them in those steps rather than weakening the type.

### Step 2: Write `mode: "full"` when a database is created

In `packages/node-api/src/lib/media-file-database.ts`, in `createDatabase`, change the `saveDatabaseConfig(rawStorage, {})` call to write `{ mode: "full" }`.

In `apps/cli/src/cmd/upgrade.ts` (around the backfill that writes `{}` when `.db/config.json` is missing), write `{ mode: "full" }` instead. A database old enough to be missing its config is by definition not a replica.

### Step 3: Write the mode during replication

In `packages/node-api/src/lib/replicate.ts`, in `replicate`, change the single `updateDatabaseConfig(destRawAssetStorage, { origin: sourcePath })` call near the end so it also writes `mode`, set to `"partial"` when `options?.partial` is true and `"full"` otherwise.

This is the one place that decides a destination's mode, and it must run for both branches, so keep it after the partial/full branch rather than duplicating it inside each.

Also in `replicate`, remove the `isPartial: true` assignments from the partial branch's `destMerkleTree.databaseMetadata` so the merkle tree stops carrying the flag. The partial branch must still copy `README.md`, `.db/files.dat` and the BSON merkle trees, and must still save the destination merkle tree, because it copies `filesImported` and `deletedAssetIds` from the source.

### Step 4: Read the mode from the config instead of the merkle tree

In `packages/node-api/src/lib/media-file-database.ts`:

- Rewrite `isDatabasePartial(databasePath, s3Config?, storageOptions?)` to create storage, call `readDatabaseMode` on the raw storage, and return whether the result is `"partial"`. It must no longer call `loadMerkleTree`. Keep the signature and the exported name so callers are unaffected.
- In `createLazyDatabaseStorage`, replace the `loadMerkleTree` call and its `databaseMetadata?.isPartial` check with a `mode` check on the config already loaded a few lines above. The function reads the config for `origin` and then loads the whole merkle tree purely to check one boolean; after this change it makes a single read and both facts come from the same object.

In `packages/node-api/src/lib/prefetch-database.worker.ts`, in `prefetchDatabaseHandler`, replace the `merkleTree?.databaseMetadata?.isPartial` early-return with a `mode` check against the config it already loads for `origin`. Drop the merkle tree load if nothing else in the handler needs it.

In `packages/node-api/src/lib/sync.ts`, replace the `isTargetPartial` derivation from `targetMerkleTree?.databaseMetadata?.isPartial` with a read of the target's mode. The surrounding behaviour (a partial target receives only `thumb/` and root-level files) must not change.

In `packages/node-api/src/lib/verify.ts`, replace the `isPartial` derivation from `merkleTree.databaseMetadata?.isPartial` with a read of the database's mode. The two places that use it (tolerating missing files and tolerating missing BSON records) keep their current behaviour.

`packages/node-api/src/lib/load-assets.worker.ts` goes through `isDatabasePartial` and `createLazyDatabaseStorage`, so it needs no change. Confirm this by inspection rather than assuming.

### Step 5: Delete the flag from the merkle tree metadata

In `packages/node-api/src/lib/media-file-database.ts`, remove `isPartial?: boolean` from `IDatabaseMetadata`. Compile and fix any remaining references. After this step, `grep -rn "isPartial" packages apps` must return no hits in TypeScript source (generated `worker.bundle.js` files and the unrelated lodash `COMPARE_PARTIAL_FLAG` matches in them do not count).

Update `packages/node-api/src/test/lib/prefetch-database.worker.test.ts`, which currently drives the handler by mocking `loadMerkleTree` to return `{ databaseMetadata: { isPartial: ... } }`. It must mock the database config instead.

### Step 6: Expose the mode in the database summary

In `packages/node-api/src/lib/media-file-database.ts`:

- Add a `mode: DatabaseMode` field to `IDatabaseSummary` with a field comment.
- `getDatabaseSummary` currently takes only `assetStorage`. It needs the raw storage to read the config, so change its signature to `getDatabaseSummary(assetStorage: IStorage, rawStorage: IStorage): Promise<IDatabaseSummary>` and populate `mode` via `readDatabaseMode`. Update every caller found by grepping for `getDatabaseSummary`.

In `apps/cli/src/cmd/summary.ts`, print a `Mode:` line alongside the existing `Files imported` / `Total files` lines, showing `full` or `partial`. When the mode is `partial`, also print the origin so the output says what the replica is partial *of*; `loadDatabase` already yields the pieces needed to read the config.

### Step 7: Show the mode in the view-database dialog

In `packages/user-interface/src/components/view-database-dialog.tsx`, add an `InfoRow` labelled `Mode` next to the existing `Origin` row, carrying a `data-id` of `database-mode` so smoke tests can read it.

The dialog renders from `IDatabaseEntry`, which has no mode field, so this needs the value plumbed through:

- Add `mode?: DatabaseMode` to `IDatabaseEntry` in `packages/node-api/src/lib/databases-config-format.ts`, and the matching `mode?: string` to `ITomlDatabaseEntry`, wiring both conversion functions in that file. Follow how `origin` is already handled: it is a cached copy of a value that lives in the database itself, refreshed when the database is opened.
- Add the same `mode?: DatabaseMode` field to the duplicate `IDatabaseEntry` in `packages/user-interface/src/context/platform-context.tsx`.
- In `apps/desktop/src/main.ts`, in the `notify-database-opened` handler that already refreshes the entry's cached `origin` from `loadDatabaseConfig`, refresh `mode` in the same place from the same config object.
- In `packages/mobile-frontend/src/lib/mobile-config-store.ts`, mirror whatever `setDatabaseOrigin` does so the mobile TOML entry carries `mode` too. Do not add a new test-only seeding path for it.

Per the repository rules, the dialog itself is a React component and gets no unit test; it is covered by the smoke test in the next step.

### Step 8: Make the replication smoke tests prove the mode

The existing replication tests cannot tell a full replica from a partial one, which is how full replication went untested for so long (recorded in `docs/plans/done/plan-fix-test-driver.md`).

- In `apps/desktop/smoke-tests/17-replicate-database/test.sh`, after the partial replication completes, assert `dest-partial/.db/config.json` contains `"mode": "partial"`. After the full replication completes, assert `dest-full/.db/config.json` contains `"mode": "full"`, and assert the destination has a non-empty `asset/` directory, which only a full replication produces.
- In `apps/cli/smoke-tests/43-replicate-partial/test.sh`, extend the existing `check_exists "$replica_dir/.db/config.json"` assertion to also check the file's `mode` is `partial`.
- In `apps/smoke-tests/tests/17-replicate-database/test.sh` (the mobile port), assert the mode through the UI: open the view-database dialog for the replica and check `database-mode` reads `partial`.

## Unit Tests

In `packages/api/src/test/lib/database-config.test.ts` (create if absent):

- `readDatabaseMode` returns `"partial"` for a config with `mode: "partial"`.
- `readDatabaseMode` returns `"full"` for a config with `mode: "full"`.
- `readDatabaseMode` returns `"full"` when `.db/config.json` does not exist.
- `readDatabaseMode` returns `"full"` when the config exists but has no `mode` field.
- `saveDatabaseConfig` round-trips `mode` and `origin` through `loadDatabaseConfig`.
- `updateDatabaseConfig` changing `origin` leaves an existing `mode` intact, and changing `mode` leaves an existing `origin` intact.

In `packages/node-api/src/test/lib/media-file-database.test.ts` (or the existing test file covering these functions):

- `isDatabasePartial` returns true for a database whose config says `partial`, false for `full`, and false when the config is missing.
- `isDatabasePartial` does not load the merkle tree. Assert this, because avoiding that load is a stated goal of the change and a regression would be silent.
- `createDatabase` writes a config containing `mode: "full"`.
- `createLazyDatabaseStorage` returns plain storage for a full database, plain storage for a partial database with no origin, and a `LazyOriginStorage` for a partial database with an origin.
- `getDatabaseSummary` reports `mode` matching the config.

In `packages/node-api/src/test/lib/replicate.test.ts` (or the existing replicate test file):

- A partial replication writes `mode: "partial"` and `origin` into the destination config.
- A full replication writes `mode: "full"` and `origin` into the destination config.
- A full replication of a partial source produces a destination whose mode is `"full"`.
- Neither mode writes `isPartial` into the destination merkle tree metadata.

In `packages/node-api/src/test/lib/prefetch-database.worker.test.ts`:

- Update the existing tests to drive partial-ness through the config rather than a mocked merkle tree, keeping the current assertions (returns early for a full database, returns early with no origin, fetches missing files for a partial database with an origin).

In `packages/node-api/src/test/lib/verify.test.ts` and the sync tests:

- A partial database tolerates missing files and missing BSON records; a full one reports them. Update whatever currently sets `isPartial` to set the config's mode instead.

In `packages/node-api/src/test/lib/databases-config-format.test.ts`:

- `mode` survives the round trip from `IDatabaseEntry` to `ITomlDatabaseEntry` and back, and an entry with no `mode` round-trips as undefined.

## Smoke Tests

- `apps/desktop/smoke-tests/17-replicate-database/test.sh`: partial replica's `.db/config.json` reports `mode: "partial"`; full replica's reports `mode: "full"` and has a non-empty `asset/` directory.
- `apps/cli/smoke-tests/43-replicate-partial/test.sh`: the partial replica's config reports `mode: "partial"`.
- A CLI check that `psi summary` prints `Mode: full` for a freshly initialised database and `Mode: partial` for a partial replica. Add it to the existing `35-database-summary` desktop test's CLI counterpart if one exists, otherwise as a new numbered CLI smoke test.
- `apps/smoke-tests/tests/17-replicate-database/test.sh`: the view-database dialog's `database-mode` reads `partial` for the replica, covering the React dialog changed in step 7.

## Verify

- `bun run compile` is clean.
- `bun run tev` passes in full (compile, unit, CLI, Electron, Android unit, Android smoke). The emulator pool must be up first; the harness will not start it.
- `grep -rn "isPartial" packages apps` returns no hits in TypeScript source.
- A newly created database's `.db/config.json` contains `"mode": "full"`, confirmed by running `psi init` on a temporary directory and reading the file.
- A partial replica's `.db/config.json` contains both `"mode": "partial"` and `"origin"`, confirmed from the artifacts left by desktop smoke test 17.
- Opening a partial replica still lazily fetches assets from its origin: desktop test 17 and mobile test 36 (`prefetch-database`) both pass, and test 36 still produces a non-empty `dest-partial/thumb` directory.

## Notes

- **The mode moves outside the integrity envelope.** `.db/config.json` is deliberately excluded from encryption (`packages/node-api/src/lib/encrypt.ts`, `decrypt.ts`) and from merkle-tree hashing, whereas `isPartial` sits inside the hashed tree today. After this change, editing one line of plain JSON flips a database's mode, and `verify` will then tolerate every missing file. That is a real reduction in tamper-resistance, accepted here because the flag's job is to describe local completeness rather than to secure anything, and because a tampered flag cannot make missing data appear. If that trade is not acceptable, the alternative is to keep the merkle tree as the authority and treat the config field as a readable mirror, at the cost of two sources of truth, which is the problem this plan exists to remove. Raise it before implementing if the security position matters more than the clarity.
- **Backward compatibility is not required** by the repository rules, so `mode` is a required field on `IDatabaseConfig` rather than an optional one. Existing databases in the wild will lack it, which is why `readDatabaseMode` defaults to `"full"`: the only databases that can be partial are ones this code created, and after this change it always writes the field.
- `"full" | "partial"` is used rather than a boolean because the ask is to make both cases obvious. `"mode": "full"` states the case positively; an absent `isPartial` states nothing.
- `getDatabaseSummary` gaining a second parameter is the one signature change that ripples. It is preferred over reading the config through the asset storage, because config reads go through raw (unencrypted) storage everywhere else in the codebase and mixing that up would produce a confusing failure only on encrypted databases.
- The dialog and CLI surfacing in steps 6 and 7 are separable. If the plan needs trimming, steps 1 to 5 deliver the structural change on their own and step 8's desktop and CLI assertions still work, since they read the file directly. Only the mobile assertion depends on step 7.
- Deleting `isPartial` in step 5 rather than leaving it in place is deliberate. Leaving both would mean two sources of truth that silently disagree the first time a code path updates one and not the other.
