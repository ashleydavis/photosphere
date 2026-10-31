# Show the database id in `psi summary` and the database summary view

## Overview

A database's identity is the uuid held in its merkle tree, and it is what decides whether two databases can sync: `psi init --database-id <id>` creates a remote that matches a database that already exists, and `psi sync` refuses two databases whose ids differ. That id is readable only through `psi database-id`, which needs the CLI and access to the database's storage. The app never displays it, so there is no way to read the id of a database that lives inside a phone's storage sandbox, and the onboarding pathway that creates a remote to match the phone's database cannot be completed. `IDatabaseSummary` is the natural carrier: it is already computed from the merkle tree that holds the id, and it is already surfaced by `psi summary`, by the database summary page and dialog, and by the `get_database_summary` MCP tool. Adding the id to it fixes every one of those surfaces at once.

## Issues

## Steps

1. **Carry the id on the Zig summary.** In `packages-zig/node-api-zig/src/lib/media-file-database.zig`, add a `databaseId: []const u8` field as the first field of `IDatabaseSummary`, with a comment saying it is the identity two databases must share to be able to sync, and populate it in `getDatabaseSummary` from `merkleTree.id`. The tree is already loaded there, so nothing extra is read. The `get-database-summary` task handler and the MCP tool both serialise the whole struct, so both carry the field with no change of their own. Add assertions to `packages-zig/node-api-zig/src/test/media-file-database.test.zig` and `packages-zig/node-api-zig/src/test/get-database-summary.worker.test.zig` that the id is returned.

2. **Update the MCP fixtures.** The MCP tests pin the exact JSON of the summary, so the new field must be added to the expected output in `apps/cli-zig/src/test/mcp-tools.test.zig`, `apps/cli-zig/src/test/fixtures/mcp-session-expected.jsonl` and wherever else the summary's JSON is pinned.

3. **Give the interface a type that carries the id.** The summary view reads the summary through the `IDatabaseSummary` type of the deprecated TypeScript `packages/node-api`, which is not to be changed. Declare the summary's shape in `packages/user-interface` instead, with `databaseId: string`, and have the view use that. Nothing under `packages/node-api` changes.

4. **Print it from the CLI.** In `apps/cli-zig/src/cmd/summary.zig`, add a `Database ID:` line first, above `Mode:`, padded to the same column as the other labels.

5. **Show it in the interface.** In `packages/user-interface/src/components/database-summary-view.tsx`, add a `SummaryRow` to the `Location` section with `dataId="database-id"` and label `Database ID`, rendered from `summary.databaseId` once the summary has loaded, above the `Path` row. This is a React component, so it gets no unit test; step 7 covers it.

6. **Cover the CLI output with a smoke test.** In `apps/cli-zig/smoke-tests-zig/lib/functions.sh`, extend `test_database_summary` (run by test 10) to capture `psi database-id --db "$TEST_DB_DIR"` and assert the summary output contains `Database ID:` followed by that exact uuid. Watch it fail against a wrong uuid first.

7. **Cover the interface with a smoke test.** In `apps/photosphere-smoke-tests/63-database-summary/test.sh`, read the seeded database's id with `run_zig_cli ... database-id` and assert the `database-id` value on the summary page matches it with `wait_for_value`, then again on the dialog opened from the navbar photo count, which mounts its own copy of the view. Watch it fail against a wrong id first.

8. **Update the documentation.** `docs/android-onboarding.md` section A2 says the app does not display the id anywhere: replace that with where it is shown (**Database Info** in the sidebar, the `Database ID` row in the Location section). In `docs/testing/e2e/mobile/auto-import/auto-import-new-remote.md` step 9, say where on the phone the id is read.

## Unit Tests

- `getDatabaseSummary` (`media-file-database.test.zig`): returns the merkle tree's id as `databaseId`, for the tree the test helper builds with a known uuid and for `test/dbs/v6`.
- `getDatabaseSummaryHandler` (`get-database-summary.worker.test.zig`): the task output carries `databaseId`, equal to the id `getDatabaseSummary` gives.
- MCP tests: the pinned summary JSON includes `databaseId`.
- No unit test for `summaryCommand` or `DatabaseSummaryView`: the CLI command is covered by the CLI smoke test, and React components are not unit tested here.

## Smoke Tests

- `apps/cli-zig/smoke-tests-zig/10-summary`: `psi summary` prints `Database ID:` with the same uuid `psi database-id` prints for the same database.
- `apps/photosphere-smoke-tests/63-database-summary`: the summary page shows the seeded database's id under `database-id`, and the dialog opened from the navbar photo count shows the same id.

## Verify

- `bun run tev` passes, in one run.
- `psi summary --db <a database>` prints a `Database ID:` line whose value equals `psi database-id --db <the same database>`.

## Notes

- `psi database-id` stays. It prints the id and nothing else, which is what a script wants; the summary is what a person reads.
- The `Location` section is where the row goes, rather than `Integrity`. `Integrity` holds hashes, which change as the database changes; the id never changes and is what the database is, alongside its path and mode.
- The other callers of the Zig `getDatabaseSummary` (`repair.zig`, `root-hash.zig`, `debug.zig`) read named fields and are unaffected by an added one.
