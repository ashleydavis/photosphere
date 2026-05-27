# Sync Early-Out

## Overview
The periodic database sync currently fetches both sides' merkle trees, walks them, acquires write locks, and writes `config.json` twice on every cycle, even when nothing has changed. This adds noticeable network and disk cost every 5 minutes per database. This plan adds a cheap pre-check at the top of `syncDatabaseHandler` that reads only the two `config.json` files and exits the sync immediately when neither side has been modified since the last successful sync. The pre-check uses a per-side opaque token treated as a string for equality; the token never crosses peers in a temporal comparison.

Two alternatives are described below for the token's data type. Pick one before executing the plan; the steps refer to the token generically as **TOKEN**.

### Alternative A: ISO timestamp string
- Field name: `lastModifiedAt` (already declared on `IDatabaseConfig`, currently unmaintained).
- Bump value: `new Date().toISOString()`.
- Snapshot fields: `lastSyncedLocalModifiedAt`, `lastSyncedOriginModifiedAt`.
- Risk: two writes in the same millisecond yield the same string, so a write captured into the snapshot at the same instant could be missed. Mitigation: advance by at least 1 ms over the previous value.

### Alternative B: Monotonic integer counter (recommended)
- Field name: `version: number` (new field).
- Bump value: `(existing ?? 0) + 1`.
- Snapshot fields: `lastSyncedLocalVersion`, `lastSyncedOriginVersion`.
- Risk: assumes a single writer per side at a time; concurrent read-modify-write could lose an increment. The existing sync already enforces a single writer via the database write lock, so this should hold.

The remainder of the plan uses **TOKEN** to refer to the chosen field and **SNAPSHOT_LOCAL** / **SNAPSHOT_ORIGIN** to refer to the chosen snapshot fields. Substitute the names from the chosen alternative when implementing.

## Issues
<empty>

## Steps

1. **Extend `IDatabaseConfig` in `packages/api/src/lib/database-config.ts`.**
   - Add (or reuse) **TOKEN** as an optional field.
   - Add **SNAPSHOT_LOCAL** as an optional field of the same type.
   - Add **SNAPSHOT_ORIGIN** as an optional field of the same type.
   - Document each field with a `//` comment block as per project rules.

2. **Add a helper `bumpToken(rawStorage)` in `packages/api/src/lib/database-config.ts`.**
   - For Alternative A: produce a fresh ISO timestamp and ensure it is strictly greater than the previously stored value (advance by 1 ms if equal).
   - For Alternative B: load existing config, compute `next = (existing?.version ?? 0) + 1`, write it back via `updateDatabaseConfig`.
   - Exported alongside the existing config functions.

3. **Identify every local-write entry point in `packages/api/src/lib/media-file-database.ts` and related operation files (asset add, asset update, asset delete, metadata edit).** For each, call `bumpToken(rawStorage)` once the write has been durably persisted (after the merkle tree update for that operation has been saved). Do not bump on reads, queries, or sync-internal writes.

4. **Guard the bump during sync.** Add a parameter or context flag that disables `bumpToken` calls while a sync is in progress, so that records written by the sync into the local side do not bump **TOKEN**. Otherwise the local side would appear modified immediately after every sync and the early-out would never fire.

5. **Insert the pre-check in `syncDatabaseHandler` at `packages/node-api/src/lib/sync-database.worker.ts`, immediately after the connectivity check (`merkleTreeExists`) at line 51 and before the `sync-started` message at line 55.**
   - Load origin config via `loadDatabaseConfig(originRawStorage)`.
   - Compare with strict equality:
     - `localConfig.TOKEN === localConfig.SNAPSHOT_LOCAL`
     - `originConfig.TOKEN === localConfig.SNAPSHOT_ORIGIN`
   - If both are true, log `Sync skipped for "..." (no changes since last sync)` and `return` without sending any messages, fetching trees, acquiring locks, or writing `lastSyncedAt`.
   - If either side is missing a stored snapshot (first sync), treat as "changed" and proceed.

6. **Update the end-of-sync write block in `syncDatabaseHandler` at lines 121-123.**
   - After `syncDatabases` completes, capture each side's current **TOKEN** (re-read each `config.json`).
   - Write to local `config.json`: `lastSyncedAt`, **SNAPSHOT_LOCAL** `= localConfig.TOKEN`, **SNAPSHOT_ORIGIN** `= originConfig.TOKEN`.
   - Continue writing `lastSyncedAt` to the origin as today.

7. **Handle the "origin has no TOKEN" case.** Older databases predate this field. Store `undefined` verbatim in **SNAPSHOT_ORIGIN**; equality on `undefined === undefined` then correctly says "unchanged" on subsequent cycles. First sync still proceeds because the snapshot field is missing.

## Unit Tests

- `database-config.test.ts`:
  - `bumpToken` advances **TOKEN** correctly (new timestamp strictly greater than previous, or counter `+1`).
  - `bumpToken` initialises **TOKEN** when the field is absent.
  - `bumpToken` preserves other fields (e.g. `origin`, `lastSyncedAt`).
  - For Alternative B: N successive `bumpToken` calls produce N increments.
- `media-file-database.test.ts` (or wherever asset operations live):
  - Asset add bumps **TOKEN**.
  - Asset update bumps **TOKEN**.
  - Asset delete bumps **TOKEN**.
  - A read-only query does NOT bump **TOKEN**.
- `sync-database.worker.test.ts`:
  - Pre-check returns early when both stored snapshots match current values; assert `syncDatabases` is not called and `sync-started` / `sync-completed` messages are not sent.
  - Pre-check proceeds when local **TOKEN** differs from **SNAPSHOT_LOCAL**.
  - Pre-check proceeds when origin **TOKEN** differs from **SNAPSHOT_ORIGIN**.
  - Pre-check proceeds on first sync (snapshot fields absent).
  - After a successful sync, both snapshot fields are written and match the values present at sync end.
  - The sync's own writes into the local database do NOT bump **TOKEN** (verifies guard in step 4).

## Smoke Tests

Add to the existing CLI sync smoke tests under `apps/cli/smoke-tests/`:

- Idle case: run sync twice back-to-back with no writes between. Assert via a spy or read-count on the origin storage that the merkle tree file is NOT fetched on the second cycle.
- Local-write case: add a photo, run sync, verify origin receives it, run sync again, assert no tree fetch on the second cycle.
- Origin-write case: simulate a change on the origin's **TOKEN**, run sync, verify it proceeds and pulls.
- First-sync case: fresh local database with no snapshot fields, run sync, verify it proceeds to full sync and writes the snapshot fields at the end.

## Verify

- `bun run compile` passes.
- `bun run test` passes (all unit tests).
- `bun run test:cli` passes (CLI smoke tests including the new idle-cycle test).
- `bun run test:electron` passes.
- Manually inspect `.db/config.json` after a sync to confirm the new fields are present and updating correctly.

## Human Verification
<not required per project rules — plans are validated by automated tests>

## Notes

- The pre-check only ever compares a value on side X to another value on side X. No cross-peer clock comparison occurs. Both sides' clocks (Alternative A) or counters (Alternative B) can be wildly out of step and the early-out still works.
- **Recommendation: Alternative B (integer counter).** It avoids the millisecond-collision risk of timestamps and makes it visually obvious that the field is not a date subject to arithmetic comparison. Smallest code surface for the bump (no clock involvement) and clearest intent.
- **Reason to prefer Alternative A:** the `lastModifiedAt` field is already declared on `IDatabaseConfig` so no new field is added, and human-readable timestamps are easier to eyeball when inspecting `config.json` by hand.
- Storage cost of the new fields is negligible (three small values).
- The pre-check adds one extra small file read from the origin per cycle (`config.json`, typically under 1 KB). This is the new floor cost when nothing has changed.
- Single-writer assumption: the bump uses read-modify-write on `config.json`. The existing sync code already assumes a single writer per database via the write lock, so concurrent bumps should not occur in practice.
