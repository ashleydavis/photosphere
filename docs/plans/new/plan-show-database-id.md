# Show the database id in `psi summary` and the database summary view

## Overview

A database's identity is the uuid held in its merkle tree, and it is what decides whether two databases can sync: `psi init --database-id <id>` creates a remote that matches a database that already exists, and `psi sync` refuses two databases whose ids differ. That id is readable only through `psi database-id`, which needs the CLI and access to the database's storage. The app never displays it, so there is no way to read the id of a database that lives inside a phone's storage sandbox, and the onboarding pathway that creates a remote to match the phone's database cannot be completed. `IDatabaseSummary` is the natural carrier: it is already computed from the merkle tree that holds the id, it is already surfaced by `psi summary`, by the database summary dialog and page, and by the `get_database_summary` MCP tool. Adding the id to it fixes every one of those surfaces at once.

## Issues

## Steps

1. **Carry the id on the summary.** In `packages/node-api/src/lib/media-file-database.ts`, add a `databaseId: string` field to `IDatabaseSummary` with a comment saying it is the identity two databases must share to be able to sync, and populate it in `getDatabaseSummary` from `merkleTree.id`. The tree is already loaded there, so nothing extra is read. Update the existing unit tests in `packages/node-api/src/test/lib/media-file-database.test.ts` and add a new one asserting the id is returned. Update the `SAMPLE_SUMMARY` fixture in `packages/node-api/src/test/lib/get-database-summary.worker.test.ts`, which will not type-check without the new field. `bun run compile` and `bun run test` must both pass before this step is finished.

2. **Print it from the CLI.** In `apps/cli/src/cmd/summary.ts`, add a `Database ID:` line to the summary output. Put it first, above `Mode:`, because it identifies the database the rest of the numbers describe, and pad the label to the same column width the existing labels use so the block stays aligned. `bun run compile` must pass before this step is finished.

3. **Show it in the interface.** In `packages/user-interface/src/components/database-summary-view.tsx`, add a `SummaryRow` to the existing `Location` section with `dataId="database-id"` and label `Database ID`, rendered from `summary.databaseId` when the summary has loaded, placed above the existing `Path` row. `SummaryRow` already renders its value in a monospace font that wraps on any character, which is what a uuid needs. This is a React component, so it gets no unit test; step 5 covers it end to end. `bun run compile` must pass before this step is finished.

4. **Cover the CLI output with a smoke test.** In `apps/cli/smoke-tests/lib/functions.sh`, extend `test_database_summary` so it captures the output of `psi database-id --db "$TEST_DB_DIR"` and asserts that the summary output contains `Database ID:` followed by that exact uuid, rather than only asserting the label is present. Run `bun run test:cli -- 10` and watch it pass, and confirm it fails first by asserting a wrong uuid before putting the real assertion in.

5. **Cover the interface with a smoke test.** In `apps/smoke-tests/tests/35-database-summary/test.sh`, after the existing `database-mode` assertion, read the id of the seeded source database with the CLI and assert the `database-id` value on the page matches it using `wait_for_value`. Assert it again on the dialog opened from the navbar photo count, since the dialog mounts its own copy of the view. Run `bun run test:and 35` and watch it pass, and confirm it fails first against a wrong id.

6. **Update the documentation to match the code.** Update the documentation for what was built, in the `summary` section of `Command-Reference.md` in the wiki working directory and in `docs/android-onboarding.md`, which says the id is not displayed anywhere: the exact label text used by the CLI (`Database ID:`) and by the summary view (`Database ID`), and where the row sits in the dialog. Correct anything that drifted during implementation.

## Unit Tests

- `getDatabaseSummary` (`packages/node-api/src/test/lib/media-file-database.test.ts`): returns the merkle tree's id as `databaseId`. The existing `buildDatabase` helper already creates the tree with a known uuid constant, so the assertion is against that constant.
- `getDatabaseSummaryHandler` (`packages/node-api/src/test/lib/get-database-summary.worker.test.ts`): the existing pass-through test covers the new field once `SAMPLE_SUMMARY` carries it. Update the fixture; add an assertion that the returned summary includes the id.
- No unit test for `summaryCommand` in `apps/cli/src/cmd/summary.ts`: CLI command functions in this repository are covered by the CLI smoke tests rather than unit tests, and this one only formats a line and exits.
- No unit test for `DatabaseSummaryView`: React components are not unit tested here. Step 5 covers it.

## Smoke Tests

- `apps/cli/smoke-tests/10-summary`: `psi summary` prints `Database ID:` with the same uuid `psi database-id` prints for the same database.
- `apps/smoke-tests/tests/35-database-summary`: the `/database-summary` page shows the seeded database's id under `database-id`, and the dialog opened from the navbar photo count shows the same id.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:cli -- 10` passes.
- `bun run test:and 35` passes.
- `bun run tev` passes, in one run, as the final check.
- `psi summary --db <a database>` prints a `Database ID:` line whose value equals the output of `psi database-id --db <the same database>`.

## Notes

- The id is already in memory wherever the summary is computed: `getDatabaseSummary` loads the merkle tree and reads `merkleTree.id`, which is the same value `psi database-id` prints in `apps/cli/src/cmd/database-id.ts`. There is no new read, no new task and no new IPC.
- Three surfaces are fixed by the one field. `apps/cli/src/lib/mcp/tools/get-database-summary.ts` serialises the whole summary object, so the MCP tool reports the id with no change of its own. The desktop and mobile both render `database-summary-view.tsx`, so both get the row.
- `psi database-id` stays. It prints the id and nothing else, which is what a script wants; the summary is what a person reads.
- The `Location` section is where the row goes, rather than `Integrity`. `Integrity` holds hashes, which change as the database changes; the id never changes and is what the database *is*, alongside its path and mode.
- Other consumers of `IDatabaseSummary` (`repair.ts`, `root-hash.ts`, `debug.ts`) read named fields and are unaffected by an added one. The only place that breaks on the new field is the test fixture, which is the intended tripwire.
