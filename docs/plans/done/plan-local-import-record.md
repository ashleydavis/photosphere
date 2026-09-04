# Move the Import Record Out of the Database and Onto the Machine That Wrote It

## Overview

The import record is one machine's account of what it imported, but it is stored inside the database it describes, at `.db/imports.dat`, and read and written through `IStorage`. Those two things contradict each other. A database on shared storage, and every S3 database, is opened by more than one machine, and each of them does a full read-modify-write of that one file with no lock and no merge, so the last writer erases what the others recorded. The file then claims to be "what this machine imported" while actually holding whatever the most recent machine happened to write. Going through `IStorage` also means every flush on an S3 database is a GET and a PUT of the whole file, once per `IMPORT_RECORD_FLUSH_SIZE` photos, and on an encrypted database it is an encrypt and decrypt of the whole file each time.

The fix is to keep it where it belongs: on the local machine, beside the other thing this machine works out about a database. `getDatabaseCacheDir(databasePath)` already exists for the hash cache and gives each database a directory of its own under the platform cache location, so the import record becomes another file in that directory. It is read and written through the local filesystem only. It must never be reached through `IStorage`, on any platform.

That also deletes a whole class of test: the record cannot travel to another database by sync, consolidation or replication, because it is not in the database at all, rather than being in the database and relying on the merkle tree not indexing it.

## Issues

## Steps

1. **Write the documentation first, then STOP.** Update `docs/automatic-photo-backup.md`: the import record section says the record lives at `.db/imports.dat`, and the "Where the cache lives" section already describes `getDatabaseCacheDir`. Rewrite the import record section to say the record is a local file in the machine's cache directory for that database, name the path layout the same way the hash cache section does, and say plainly that it is never read or written through `IStorage` and never travels. Say what happens to a record written by an older version (see the open question in Notes). Do not start any later step. Report that the documentation is ready and wait for the human to approve it. If the human revises it, revise the remaining steps here to match before implementing anything.

2. **Give the import record a path under the database cache directory.** In `packages/node-api/src/lib/database-cache-dir.ts`, add `getImportRecordPath(databasePath: string): string` returning `imports.dat` inside `getDatabaseCacheDir(databasePath)`. Keep the constant naming the file beside it rather than inlining the string. Leave `IMPORT_RECORD_PATH` in `packages/api/src/lib/import-record.ts` alone in this step; step 6 removes it.

3. **Read and write the record through the local filesystem.** Rewrite `packages/node-api/src/lib/import-record-storage.ts` so `loadImportRecord` and `recordImports` take a `databasePath: string` instead of an `IStorage`, and use `fs/promises` against `getImportRecordPath(databasePath)`. Drop the `IStorage` import entirely: nothing in this module may reach storage again. `loadImportRecord` keeps its "never throws, returns an empty record" behaviour for a missing or unreadable file. `recordImports` must create the directory if it is not there.

4. **Make concurrent writers on one machine merge rather than clobber.** `recordImports` currently reads, modifies and writes with nothing in between, so the CLI and the desktop app importing into the same database at the same time lose each other's entries. Use `updateJson` (or `updateFileOptimistic`) from `node-utils`, which runs the mutator under an update lock beside the file and re-runs it if the file moved underneath. The mutator is the existing `addImportEntries` call. The record is stored as JSON today, so `updateJson` fits without changing the format.

5. **Update the two callers.** `packages/node-api/src/lib/import-assets.worker.ts` calls `recordImports(storage, entriesToWrite)` in `flushImportRecord`; pass the database path it already has instead. `packages/node-api/src/lib/get-import-record.worker.ts` calls `loadImportRecord(storage)` after `openStorage(data.databasePath)`; it can now call `loadImportRecord(data.databasePath)` and stop opening storage at all, which also makes reading the record work for a database whose credentials are missing.

6. **Remove the old location.** Delete `IMPORT_RECORD_PATH` from `packages/api/src/lib/import-record.ts` and rewrite that file's header comment, which currently explains that the record lives in `.db/imports.dat` and stays out of sync by not being in the merkle tree. Neither is true afterwards. Nothing else in `packages/api` may keep a path: the location is node-api's, because only node-api has a filesystem.

7. **Point the smoke tests at the new location.** `apps/cli/smoke-tests/87-import-record/test.sh` and `apps/desktop/smoke-tests/35-auto-import/test.sh` both build `$DB/.db/imports.dat` by hand. They cannot derive the new path in shell without duplicating the hash of the database path, which would then rot silently when the derivation changes. Add a hidden CLI command that prints it, following `psi hash-cache dir --db <path>` exactly: register it in `apps/cli/index.ts` and implement it beside the other hidden tools. Then change both tests to ask for the path rather than build it.

8. **Cut the tests that no longer describe anything.** In `apps/cli/smoke-tests/87-import-record/test.sh`, part 3 asserts that consolidate, sync and replicate each leave `.db/imports.dat` behind. Those checks were guarding an exclusion that no longer has to be arranged, because the file is not in the database. Replace them with one check that the database directory contains no `imports.dat` at all after those three operations, so a later change that puts it back inside the database fails here. Do not simply delete the section.

9. **Update the documentation to match.** Revisit `docs/automatic-photo-backup.md` against the finished code and correct anything that changed while implementing, including the answer to the open question in Notes if it was decided during the work.

Every step must compile (`bun run compile`) and leave `bun run test` passing before it is considered done.

## Unit Tests

- `packages/node-api/src/test/lib/database-cache-dir.test.ts` — `getImportRecordPath` sits inside `getDatabaseCacheDir` for the same database; two databases get two different paths; the same database gets the same path every time.
- `packages/node-api/src/test/lib/import-record-storage.test.ts` (new) — a record round-trips through `recordImports` and `loadImportRecord` against a real temp directory; `loadImportRecord` returns an empty record when the file is absent, when it is not JSON, and when it is JSON but not a record; `recordImports` creates the directory when it does not exist; `recordImports` with no entries writes nothing; the cap in `addImportEntries` still applies through the save path.
- The same file — two overlapping `recordImports` calls both survive, which is what step 4 is for. Write it so it fails against a plain read-modify-write.
- `packages/node-api/src/test/lib/get-import-record.worker.test.ts` — the handler returns the record for a database path without opening storage.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — the existing import record assertions still hold with the worker passing a path rather than a storage.

## Smoke Tests

- `apps/cli/smoke-tests/87-import-record/test.sh` — as amended by steps 7 and 8: the record is written to the local path the CLI reports, holds both the manual and the automatic import, and no `imports.dat` appears anywhere inside the database directory after consolidate, sync and replicate.
- Same test — a second database on the same machine gets its own record, and importing into one does not appear in the other. This is what the per-database cache directory buys and nothing covers it today.
- `apps/desktop/smoke-tests/35-auto-import/test.sh` — the desktop app writes the record to the same local path the CLI reports for that database, which is what proves the two agree on the location.
- `bun run test:and` — the Import page on Android still shows what the database has imported, which is the mobile path through `get-import-record` and the sandbox-relative cache directory.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes.
- `bun run test:parallel` passes, because the record now lives under `PHOTOSPHERE_CACHE_DIR`, which the test temp allocator sets per run. A suite that reaches the developer's real record shows up here.

## Notes

- The reason this is worth doing is not tidiness. Today two machines importing into one S3 database silently destroy each other's record, and the file goes on presenting itself as a complete account. Read-modify-write with no lock is the whole mechanism.
- `getDatabaseCacheDir` and the platform cache locations behind it already exist and are documented in `docs/automatic-photo-backup.md`. This plan adds a file to that directory and nothing else about the layout changes.
- **Open question: encrypted databases.** Today the record goes through `IStorage`, so on an encrypted database it is encrypted at rest. Written to the local filesystem it is plaintext, and it holds logical paths and a base64 micro thumbnail per entry. That is a privacy regression for exactly the users who asked for encryption. Decide before step 3 whether the local record should be encrypted with the database's key, whether the micro thumbnails should be dropped from it, or whether plaintext is acceptable because the imported files themselves were sitting in plaintext on the same machine anyway. This is the one part of the plan that is not obviously right.
- **Open question: existing records.** Databases in the wild have a `.db/imports.dat` written by the current code. Backward compatibility is not required here, so the new location simply starts empty. Decide whether the old file should be left alone (a stale file inside every existing database forever), or deleted when the database is next opened. Deleting is user data and should not be decided by an implementing agent.
- The record already survives a restart today because it is in the database. It will still survive one afterwards, because the platform cache location is not a temp directory. It does not survive the user clearing their caches, which is a change: clearing caches loses the history of what was imported, and unlike the hash cache that cannot be recomputed. If that is unacceptable the record belongs in the config directory rather than the cache directory, which is a one-line difference in step 2 and should be decided with the encryption question above.
- `packages/user-interface/src/context/import-context.tsx` reaches the record only through the `get-import-record` task, so no user interface code changes.
