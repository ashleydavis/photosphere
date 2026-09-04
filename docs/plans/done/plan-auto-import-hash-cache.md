# Stop Rehashing Photos That Are Already Imported

## Overview

On mobile, automatic import hashes every photo from scratch, every time, and the hash cache never once helps. Across a test run on a Pixel 6, 143 of 143 hashes were computed rather than read from the cache. The cause is that a photo in the device library is not a file the import can open, so each one is copied into a sandbox temp file first, and the cache is keyed on the file path with the size and last modified time as the check. A fresh copy has a new modification time, so the lookup can never match. The cache also lives in a process temp directory that does not survive the app restarting. The result is that the whole library is copied and hashed again on every run, which is the single largest cost in an import and the reason importing runs at roughly 5 photos a minute.

## Issues

## Steps

1. **Record what a photo was imported from.** The device library gives each item a stable id, a size and a modification time (`packages/mobile-worker/src/lib/device-media-source.ts` lists them, and `IMediaItem` carries them). Extend the import record in `packages/api/src/lib/import-record.ts` so an entry can hold the source identity it came from: the source id, the size and the modified time. Keep it optional so existing records still load, and keep the record's existing entries unchanged in meaning.

2. **Write the source identity when a photo is imported.** `packages/api/src/lib/auto-import-loop.ts` already maps an exported temp path back to its source id in `sourceIdByImportPath` for cleanup. Carry the size and modified time alongside it, and pass the identity through to whatever writes the import record entry so it lands with the imported asset.

3. **Skip a photo whose source identity is already recorded.** In `packages/api/src/lib/auto-import-loop.ts`, before `source.openItem` copies anything, check the item's source identity against what the record holds. A match means the photo is already in the database: count it as skipped and move on, without copying it to temp and without queueing a hash. The check has to be against the database's own record rather than an in-memory set, so it survives a restart, which is exactly what the current cache does not do.

4. **Load the recorded identities once per run.** Reading the whole import record for every item would be worse than the hashing. Load the set of recorded source identities when the loop starts, keep it in memory, and add to it as photos are imported. `loadDatabaseHashes` in `packages/node-api/src/lib/auto-import.worker.ts` is the existing precedent for loading something once from the database for the loop to use.

5. **Decide what happens when a photo has changed.** A source id that matches with a different size or modification time is an edited photo, not one already imported. It must not be skipped. Make the identity check require all three parts to match, and confirm the import path still deduplicates by content hash afterwards so an edit that produced identical content is still recognised.

6. **Give the hash cache a home that survives a restart, or remove it.** `packages/node-api/src/lib/import-assets.worker.ts` builds the cache path from `getProcessTmpDir()`, which on mobile does not persist. Once step 3 stops the copies happening at all for photos already imported, decide whether the cache still earns its place on mobile. If it does, move it under the database directory rather than a temp directory. If it does not, leave it for the desktop and say so in the code comment, so the next reader does not assume it is working on mobile.

7. **Confirm the cost is gone.** Add a counter to the progress message for how many items were skipped without being copied, so the next run over an already-imported library can be seen to do no copying and no hashing.

Every step must compile (`bun run compile`) and leave the unit tests passing before it is considered done.

## Unit Tests

- `packages/api/src/test/lib/import-record.test.ts` — an entry round-trips with a source identity; an entry written by the old format still loads.
- `packages/api/src/test/lib/auto-import-loop.test.ts` — an item whose source identity is already recorded is skipped without `openItem` being called; an item with the same id but a different size or modified time is imported; a fresh item is imported; the in-memory set grows as items are imported so the same item is not offered twice in one run.
- `packages/node-api/src/test/lib/auto-import.worker.test.ts` — the recorded identities are loaded once when the loop starts, not per item.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — if the cache location changes in step 6, a test that the cache is found again after the process temp directory is gone.

## Smoke Tests

- Android and iOS suites in `apps/smoke-tests/`: import a seeded library, restart the app, and assert the second run copies and hashes nothing. Assert on the skipped-without-copy counter from step 7, since a run that silently does the work again looks the same from outside.
- Android and iOS suites: change a photo in the library after it has been imported and assert it is imported again rather than skipped.
- `bun run test:cli`: the desktop import still uses its hash cache and still deduplicates, so a second import of the same folder adds nothing.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes.
- On a device: restart the app with automatic import on over a library already imported, and confirm from the log that no hash tasks run for photos already in the database.

## Notes

- Evidence from the test session: every hash task in the log reported `hashFromCache: false`, 143 out of 143. The library was 2,183 photos and 120 videos, 2.6 GB of images, and the import managed about 5 photos a minute.
- The copy to temp is not itself removable: a photo in the device library is not a file the import can open, which is what `openItem` exists for. The saving comes from not copying photos that are already in the database, not from removing the copy.
- Fixing this raises the import rate, which shortens every batch. It does not fix the app being unresponsive during an import: that needs the priority work in the responsiveness plan.
- Open question for step 1: whether the source identity belongs in the import record or somewhere else in the database. The import record is already written per imported asset and already travels with the database, but it is capped in size and older entries are dropped, so identities could be lost for the oldest photos. Check what the cap is before committing to it, because a dropped identity means that photo gets copied and hashed again.
