# Names stop being unique: the path identifies a database, the name describes it

## Overview

A database is identified three ways at once and they disagree: the uuid in its merkle tree is its real identity, its credentials and encryption key are found by exact path match against `databases.toml`, and its entry in that file is keyed by name, unique per device and chosen independently on each. That last one is the odd one out, and it breaks the ordinary case: two copies of one database, a local one and the remote it syncs with, cannot both be called what the database is called, because the list refuses the second. Setting up an Android phone against an existing bucket database ran straight into it, and the way out was to rename one copy so the other could have the name. **The decision is made: the path is the identifier and the name is a description.** Names need not be unique, so a local database and its remote can share one. `psi` takes either a path or a name, and where a name matches more than one entry, `--type=fs` or `--type=s3` says which is meant. The interface shows a badge on every database saying what kind of storage it lives in, so two entries with one name are told apart on sight rather than by opening each.

## Issues

## Steps

1. **Write the documentation first, then stop.** This changes what the user types and what they see, so it is documented before it is built.
    - `docs/storage-paths.md`: it describes every path form and says nothing about names. Add what a name is for, that it need not be unique, that the path is what identifies a database, and how `--db` resolves a value that could be either.
    - The wiki working directory: `Managing-Databases.md` and `Configuration-Databases.md` (both describe names as unique), and the `--db` and `dbs` sections of `Command-Reference.md`, which gain `--type`.
    - `docs/android-onboarding.md`: the "Replicating it down to the phone" section tells the reader to rename the remote's entry to free up its name for the local copy. That workaround goes.
    - **STOP when the draft is written and wait for the human to review it.** If the human revises it, revise the steps below to match before implementing.

2. **Make the path the key on disk.** In `packages/node-api/src/lib/databases-config-format.ts`, rename the recents field from `recent_database_names` to `recent_database_paths` in `ITomlDatabasesConfig` and `recentDatabaseNames` to `recentDatabasePaths` in the in-memory config, and add a read-time migration: an old file's recent names are matched against the entries and rewritten as paths, and a name that matches nothing is dropped rather than kept as a path that resolves to nothing. `last_database` is already a path and does not change. Every changed function gets a unit test, including the migration and a file that has both keys. Compile and tests pass.

3. **Make the path the key in the lookups.** In `packages/node-api/src/lib/databases-config.ts`:
    - `addDatabaseEntry` rejects a duplicate **path** and stops rejecting a duplicate name.
    - `findDatabase(name)` is replaced by `findDatabaseByPath(path)` and `findDatabasesByName(name)`, the second returning every match rather than the first.
    - `updateDatabaseEntry(originalName, entry)` becomes keyed by path, which removes the rename-collision check and the rewrite of the recents list on a rename: a rename no longer moves anything.
    - `removeDatabaseEntry` and the recents helpers take paths.
    Unit tests per function, including two entries sharing a name. Compile and tests pass.

4. **Write the resolution rule as a pure function.** Add it beside `resolveDatabaseEntry` in `apps/cli/src/lib/init-cmd.ts`, taking the entries, the `--db` value and the optional type, and returning either one entry, nothing, or the list of candidates when it is ambiguous. The rule: an exact path match wins outright; otherwise every entry whose name matches case-insensitively is a candidate; a single candidate is the answer; more than one is filtered by the type when one was given; more than one after that is ambiguous. Note that `--type` only separates candidates that differ in storage kind, so two S3 databases sharing a name are still ambiguous and must be reported as such: the error lists each candidate with its path, as the current ambiguity error does. Unit tests for every branch, including the case where the type filter leaves nothing. Compile and tests pass.

5. **Wire the rule into the CLI.** `resolveDatabaseEntry` in `apps/cli/src/lib/init-cmd.ts` calls the step 4 function and reports the ambiguous case. Add a `--type <fs|s3>` option in `apps/cli/index.ts` beside the existing `dbOption`, defined once and added to every command that takes `--db`, and to the `dbs` subcommands that take `--name` (`view`, `edit`, `remove`, `send`), whose lookups move from `findDatabase` to the same rule. Compile and tests pass.

6. **Add the badge label.** In `packages/user-interface/src/lib/database-summary-format.ts`, beside the existing `getStorageType` (which returns a full phrase such as "S3-compatible object storage", too long for a badge), add a function returning the short label a badge shows, derived from the same path prefixes. Unit test it in `packages/user-interface/src/test/lib/database-summary-format.test.ts` for each path form in `docs/storage-paths.md`, including a bare relative path, which is what every mobile database is.

7. **Show the badge everywhere a database is listed.** `packages/user-interface/src/pages/databases/databases-page.tsx` (the cards and the desktop table), `open-database-modal.tsx`, and the recents section of `left-sidebar.tsx`. Give the badge a `data-id` so the smoke tests can read it. These are React components: no unit tests, covered end to end below.

8. **Stop the interface enforcing unique names.** `add-database-modal.tsx`, `create-database-modal.tsx` and `edit-database-modal.tsx` each block a duplicate name today; they must block a duplicate **path** instead, with a message naming the entry that already has it. `receive-database-dialog.tsx` loses its `db-name-conflict` step entirely, which is what lets a shared database arrive under the name the sender gave it: a database received twice is now a path conflict, not a name conflict, and that is the case the step is rewritten to handle.

9. **Follow the rename through mobile.** `packages/mobile-frontend/src/lib/mobile-databases-config-file.ts` carries `recentDatabaseNames` through the worker boundary, and `removeRecentDatabaseName` on `IPlatform` in `packages/user-interface/src/context/platform-context.tsx` takes a name, called from `left-sidebar.tsx` with `dbEntry.name`. Both become paths, in both providers. Compile and tests pass.

10. **Name a replica after the database it copies.** When `plan-register-replica-in-database-list.md` has landed, the entry a replication registers is named from the destination path's last segment. Change it to take the source entry's name when the source is registered, falling back to the last segment when it is not, so a local replica and its remote share one name, which is the case that started this. If that plan has not landed yet, fold this requirement into it rather than duplicating the work here.

11. **Update the documentation to match the code**, including the exact badge labels and the exact ambiguity error the CLI prints.

## Unit Tests

- `packages/node-api/src/test/lib/databases-config-format.test.ts`: the TOML conversions in both directions with the new recents key; the migration from `recent_database_names`, including a name matching no entry and a file carrying both keys.
- `packages/node-api/src/test/lib/databases-config.test.ts`: `addDatabaseEntry` accepts a duplicate name and rejects a duplicate path; `findDatabaseByPath`; `findDatabasesByName` returning more than one; `updateDatabaseEntry` keyed by path, including a rename that leaves the recents list untouched; the recents helpers by path.
- `apps/cli/src/test/lib/init-cmd.test.ts`: the resolution function for each branch (exact path, one name match, several names filtered to one by type, several after the filter, no match at all, a type that filters everything out).
- `packages/user-interface/src/test/lib/database-summary-format.test.ts`: the badge label for `s3:`, `fs:`, an absolute path, a Windows path and a bare relative path.
- No unit tests for the modals, the databases page, the sidebar or the receive dialog: React components are covered end to end.

## Smoke Tests

- `apps/cli/smoke-tests`: two databases registered under one name, one on the filesystem and one in a bucket; `--db <name>` fails naming both candidates, `--db <name> --type=s3` picks the bucket one, and `--db <the path>` picks either without a type.
- `apps/cli/smoke-tests`: `psi dbs add` accepts a second entry with an existing name, and refuses a second entry with an existing path.
- `apps/smoke-tests/tests/26-receive-database`: a database received whose name is already taken imports under that same name, with no conflict step, and the list then shows two entries with one name and different badges.
- `apps/smoke-tests/tests/6-add-database-entry`: the Manage Databases page shows the storage badge on each entry.
- `apps/smoke-tests/tests/16-remove-recent-database`: the recents list still removes the right entry once recents are keyed by path, with two entries sharing a name.
- An existing `databases.toml` holding `recent_database_names` loads, and its recents survive as paths.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:cli` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- On a phone, a local replica and the remote it syncs with both carry the database's name, are told apart by their badges, and both open.

## Notes

- **What was decided.** The path identifies a database; the name describes it and need not be unique. `psi` accepts a path or a name, and `--type=fs` or `--type=s3` disambiguates a name that matches more than one. The interface badges every listed database with its storage kind.
- **The name stays in the entry, not in the database.** Storing it inside the database was considered so that copies would agree automatically. It is not needed: `dbs send` already carries the sender's name with the entry, and the only thing stopping the receiver from keeping it was the uniqueness rule this plan removes. Putting the name in the database would also make renaming a write to storage, which is impossible on a remote nobody can write to and awkward on one that is offline.
- **`--type` is not a complete tie-breaker,** and the plan does not pretend it is. Two databases in two different buckets can share a name, and so can two on the filesystem. The rule ends in the same ambiguity error that exists today, listing each candidate with its path, which is the only thing that always distinguishes them.
- **Three identifiers become two.** The uuid remains the identity that decides whether two databases can sync, and it is still not displayed anywhere (`plan-show-database-id.md` fixes that). After this plan, the name is a label with no lookup behaviour of its own beyond being a convenience for the CLI.
- **Secret names are still derived from the database name** by `inferSecretName` in `apps/cli/src/cmd/dbs.ts` (`<db name>:s3`, `<db name>:enc`), and `resolveUniqueSecretName` already handles the collision that non-unique database names make more likely. Nothing here changes that, but it is the one place where a duplicate name still has a consequence.
- **The path-keyed credential lookup does not change.** `resolveStorageCredentials` matches `dbEntry.path === databasePath` exactly, and an entry that fails to match resolves to no credentials rather than an error, surfacing much later as an access failure from the storage layer. This plan makes the path more load-bearing, not less, so that exact match stays exact.
