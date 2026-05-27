# Expand the E2E Testing Manual

## Overview

The manual testing scripts under `docs/testing/e2e/` currently cover only a
small slice of what the CLI and Electron smoke tests already exercise. This
plan lists the test cases that should be added to the manual so that
human-followable, automation-free walkthroughs exist alongside each major
behaviour that the smoke tests automate. Each new entry should follow the
existing format (Prerequisites, numbered Steps, Expected results) used in
files like `docs/testing/e2e/cli/import/add-and-verify.md`.

## Steps

### CLI manual tests to add

Group these under `docs/testing/e2e/cli/<area>/` directories, creating new
subdirectories where none exists yet.

1. `cli/import/`
    1. Add a PNG file.
    2. Add an MP4 video file.
    3. Add the same file twice (verify no duplication).
    4. Add multiple files in one command.
    5. Add a directory containing duplicate content (dedupe to one asset).
    6. Attempt to create a database in a directory that already contains one (must fail, no overwrite).

2. `cli/inspect/` (new)
    1. `summary` output for a populated database.
    2. `export` an asset by ID to a chosen destination.

3. `cli/verify/` (new)
    1. `verify --full` (full integrity scan vs. quick scan).
    2. Detect a deleted file via `verify`.
    3. Detect a modified file via `verify`.
    4. `repair` on a clean database (no changes expected).
    5. `repair` a damaged database using a replica as the source of truth.

4. `cli/remove/` (new)
    1. `remove` an asset by ID and confirm it is gone.

5. `cli/compare/` (new)
    1. `compare` two identical databases.
    2. `compare` after changes (one DB ahead of the other).

6. `cli/sync/` (new)
    1. Sync original → copy.
    2. Sync copy → original.
    3. Sync after editing a field with `bdb-cli` (both directions).
    4. Sync after deleting an asset (both directions).

7. `cli/replication/` (extend)
    1. Replicate a database that has a deleted asset.
    2. Replication fails between two unrelated databases.
    3. Re-replicate with no changes (second run is a no-op).
    4. Replicate incremental changes after adding new files.

8. `cli/upgrade/` (new)
    1. v2 database is read-only (summary/verify suggest upgrade).
    2. Write commands (add, remove) fail on v2.
    3. Upgrade v2 → v6.
    4. Upgrade v3 → v6.
    5. Upgrade v4 → v6.
    6. Upgrade v5 → v6.
    7. v6 → v6 upgrade is a no-op.
    8. Add a file to a freshly-upgraded v6 database.

9. `cli/dbs/` (new)
    1. `dbs list` with no entries shows empty message.
    2. `dbs add` (seeded) then `dbs list` shows it.
    3. `dbs view` shows name, path, secret IDs.
    4. `dbs edit` (rename a database entry).
    5. `dbs add` via CLI flags.
    6. `dbs add` with duplicate name fails.
    7. `dbs remove --yes` removes the entry.
    8. `dbs clear --yes` removes all entries.
    9. Resolve database by name.
    10. Resolve database by path.
    11. "Did you mean" hint when name does not match (no-match fallback).

10. `cli/vault/plaintext/` (new)
    1. Empty vault shows "No secrets" message.
    2. Add a secret.
    3. View a secret.
    4. Edit a secret value.
    5. Delete a secret.
    6. Add a secret with duplicate name fails.
    7. `secrets clear --yes` removes all.
    8. Import a PEM key pair.
    9. `vault list` showing shared secrets.

11. `cli/vault/keychain/` (new)
    1. The same add/view/edit/delete/list cycle against the OS keychain backend.
    2. Listing multiple keychain secrets.

12. `cli/lan-share/` (new)
    1. Share a secret over LAN (sender → receiver).
    2. Share a database entry over LAN.

13. `cli/misc/` (new)
    1. `config` shows `lastModifiedAt` / `lastSyncedAt` timestamps and confirms they update across add/sync/repair.
    2. `mcp` server starts and serves resources.

### Desktop manual tests to add

Group under `docs/testing/e2e/desktop/<area>/`.

1. `desktop/database/` (new)
    1. Open an existing database from disk.
    2. Load a pre-populated fixture (e.g. the 50-asset fixture) and verify the gallery renders.
    3. View database details page (name, path, asset count).
    4. Edit a database's origin path.
    5. Remove a database from the "Recent databases" list.
    6. Add an external database entry (link a CLI-created DB into the app).

2. `desktop/secrets/` (new)
    1. Add a secret via the UI.
    2. View a secret value.
    3. Edit an encryption-key secret (raw PEM, no JSON envelope).
    4. Edit an API-key secret.
    5. Edit an S3-credentials secret (JSON envelope).
    6. Rename a secret (vault key matches its name).
    7. Adding a secret with a duplicate name shows an error.

3. `desktop/lan-share/` (new)
    1. Share a secret from sender app to receiver app.
    2. Share a database entry from sender app to receiver app.

4. `desktop/news/` (new)
    1. News notifications appear and can be dismissed.

5. `desktop/mcp/` (new)
    1. MCP server runs from within the desktop app.

### Index updates

1. Update `docs/testing/e2e/cli/README.md` to list the new subdirectories.
2. Update `docs/testing/e2e/desktop/README.md` to list the new subdirectories.
3. Add a short `README.md` inside each new subdirectory listing the tests it contains, matching the style of the existing per-area READMEs.

## Unit Tests

No unit tests are required: these manual test scripts are prose documents.
The underlying functionality is already covered by the CLI and Electron
smoke tests (`apps/cli/smoke-tests/`, `apps/desktop/smoke-tests/`), which is
what this manual mirrors for human use.

## Smoke Tests

No new smoke tests. Each new manual test is a documented walkthrough of
behaviour already covered by an existing automated smoke test. If gaps are
discovered while writing a manual test (a step that cannot be carried out
because the feature is unimplemented or broken), the writer should add a
`> **Warning:**` note at the top of the file in the same style as
`cli/move/move-file-between-databases.md`.

## Verify

1. `find docs/testing/e2e -type f -name '*.md' | sort` lists a file for each test in the Steps section above.
2. Each new `.md` follows the existing template: top-level title, Prerequisites, numbered Steps, and Expected results.
3. Each parent `README.md` (cli, desktop, and each area) links to every file in its directory.
4. Spot-check three manual tests end-to-end by following them by hand against a working source checkout and confirm the Expected results occur.

## Notes

1. Areas already covered by the manual (and therefore not in this plan): `cli/import/add-and-verify`, `cli/move/move-file-between-databases`, `cli/replication/replicate-full-copy`, `cli/replication/replicate-partial-copy`, plus the equivalent four files under `desktop/`, and `desktop/download/{single,multiple}`.
2. The numbering used by the smoke tests (`01-create-database`, etc.) is intentionally not mirrored in the manual: organise by area, not by smoke-test index, so the docs do not need renumbering when smoke tests are added or reordered.
3. Some smoke tests (e.g. version upgrades, repair-damaged) require fixture databases shipped in the repo. The manual versions of those tests should reference the same fixture paths so a tester can reproduce them without rebuilding the fixtures.
4. Open question: should LAN-share manual tests be split into "sender" and "receiver" walkthroughs, or written as a single walkthrough that assumes the tester has two machines / two app instances? Decide before writing those files.
5. Open question: the MCP smoke tests cover both CLI and desktop; the manual versions should probably share a single "how to verify MCP" appendix rather than duplicating the connection steps.
