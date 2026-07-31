# Show the database mode (full or partial) in the CLI summary and the UI

## Overview

Nothing a user can see says whether the database in front of them is a full copy or a partial replica. The fact is recorded as `isPartial` in the merkle tree's `databaseMetadata` (`packages/node-api/src/lib/media-file-database.ts`), where only the replication, sync, prefetch and verify code paths read it. This plan leaves that field exactly where it is and does one thing: reports it. `psi summary` gains a `Mode:` line, and the Database Summary page gains a `Mode` row. Both read the same value from the same place, because `getDatabaseSummary` already loads the merkle tree, so the value costs nothing extra to obtain and needs no new plumbing on any platform.

An earlier version of this plan moved the flag into `.db/config.json`. That is abandoned. The flag stays in the merkle tree.

## Issues

## Steps

Each step must leave `bun run compile` clean and `bun run test` passing before it is considered done.

### Step 1: Report the mode in the database summary

In `packages/node-api/src/lib/media-file-database.ts`:

- Add an exported string-union type `DatabaseMode` with the values `"full"` and `"partial"`, with a comment block explaining that `"partial"` means only the `thumb` directory's assets are present locally and the rest are fetched lazily from the database's origin.
- Add a required `mode: DatabaseMode` field to `IDatabaseSummary`, with a field comment.
- In `getDatabaseSummary`, populate it from the merkle tree the function has already loaded: `merkleTree.databaseMetadata?.isPartial === true ? "partial" : "full"`.

`getDatabaseSummary` keeps its current signature. It already has the tree in hand, so no caller changes and no storage is threaded anywhere.

Do not touch `IDatabaseMetadata`. `isPartial` stays as it is and remains the only place the fact is recorded. `DatabaseMode` is a presentation type: it exists so the two surfaces spell the two cases the same way, not as a second source of truth.

### Step 2: Print the mode in `psi summary`

In `apps/cli/src/cmd/summary.ts`, print a `Mode:` line above the existing `Files imported:` line, showing `full` or `partial`, coloured like its neighbours.

Nothing else in the command changes. The origin of a partial replica is already reported by `psi origin`, so the summary does not repeat it.

### Step 3: Show the mode on the Database Summary page

In `packages/user-interface/src/pages/database-summary.tsx`:

- Add a `dataId: string` field to `ISummaryRowProps` and render it as `data-id` on the row's outer `Box`, so smoke tests can read a row's value. Pass an id at each of the existing call sites (`database-path`, `database-storage-type`, `database-files-hash`, `database-database-hash`, `database-full-hash`).
- Add a `SummaryRow` labelled `Mode` with `data-id` of `database-mode`, value `summary.mode`, to the `Location` section. It needs `summary`, so it goes inside a `summary &&` guard rather than in the unconditional `Location` block as it stands. Either move the whole section under that guard or render the Mode row conditionally; pick whichever leaves the smaller diff.

This is the shared UI package, so one change lands on desktop, web, iOS and Android at once, with no platform-specific code.

### Step 4: Fix the fixture that will no longer typecheck

`packages/node-api/src/test/lib/get-database-summary.worker.test.ts` declares `SAMPLE_SUMMARY` as a typed `IDatabaseSummary` literal. Adding a required field breaks it. Add `mode` to that literal. It is the only `IDatabaseSummary` literal in the repository, confirmed by grepping for `totalNodes`.

## Not in scope

- **The view-database dialog.** It renders `IDatabaseEntry`, which is the cached entry in `databases.toml`, not the live database. Putting the mode there means copying it into the cache and refreshing it per platform, which is a second copy that can disagree with the database and different code on desktop and mobile. The Database Summary page reads the live value instead, on every platform, with no cache.
- **Moving the flag.** `isPartial` stays in the merkle tree. The costs of that were weighed and accepted: reading it loads the whole tree file, and `origin` continues to live in a different file in a different format.
- **`verify` tolerating missing files on a partial database.** Today a partial database counts every missing file as unmodified, so real corruption is invisible. That is a genuine problem and it predates this work, but it is a behaviour change and belongs in its own plan.

## Unit Tests

There is no `media-file-database.test.ts` today, so create `packages/node-api/src/test/lib/media-file-database.test.ts`. Build a database in a `MockStorage` following the pattern in `replicate.test.ts` (`createTree` / `addItem` / `saveTree`), setting `databaseMetadata` as each case needs:

- `getDatabaseSummary` reports `mode` as `"partial"` when the tree's `databaseMetadata.isPartial` is true.
- `getDatabaseSummary` reports `mode` as `"full"` when `isPartial` is false.
- `getDatabaseSummary` reports `mode` as `"full"` when `databaseMetadata` is absent entirely, which is what an older database looks like.

Per the repository rules the summary page is a React component and gets no unit test; it is covered by the smoke tests below.

## Smoke Tests

- `apps/cli/smoke-tests/10-summary`: `test_database_summary` in `apps/cli/smoke-tests/lib/functions.sh` gains an assertion that the output contains `Mode:` and reads `full`. The database it summarises is freshly initialised, so `full` is the only correct answer.
- `apps/cli/smoke-tests/43-replicate-partial`: after the existing origin check, run `psi summary` against the replica and assert the output reports `partial`, and run it against the source and assert `full`. The test already builds both, so this needs no new fixture.
- `apps/smoke-tests/tests/35-database-summary`: after the existing `Database summary loaded:` wait, assert `database-mode` reads `full` with `wait_for_value`. This is the test that proves the React change, and it runs on Android and iOS.

There is no desktop smoke test for the Database Summary page. None is added: the page is the same shared component the mobile test drives, and adding a desktop test for it is a separate gap from this change.

## Verify

- `bun run compile` is clean.
- `bun run tev` passes in full (compile, unit, CLI, Electron, Android unit, Android smoke). The emulator pool must be up first; the harness will not start it.
- `psi summary` on a freshly initialised database prints `Mode: full`.
- `psi summary` on the partial replica left by CLI smoke test 43 prints `Mode: partial`.

## Notes

- Nothing on disk changes. No new file, no new field, no migration. Every existing database reads correctly, and a database written by this build is unchanged from one written by the previous build.
- An older database whose tree has no `databaseMetadata` reports `full`. That is correct: only this code creates partial replicas, and it has always written the flag when it does.
- `"full" | "partial"` is used at the surface rather than showing a raw boolean, because the point of the change is to state both cases plainly. `Mode: full` says what the database is; `isPartial: false` makes the reader work it out.
