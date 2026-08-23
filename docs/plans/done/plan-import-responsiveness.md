# Keep the App Responsive While Importing

## Overview

Automatic import currently takes the whole machine. On a Pixel 6 with 2,300 photos in the library, tapping a database took 2 minutes 8 seconds to open, and a photo taken with the camera did not appear for 42 minutes. Neither is a slow disk or a slow phone: the import queues one task per file with nothing holding it back, all tasks share a single first-come-first-served queue with no notion of who is waiting, and the loop only looks for new photos between batches of up to 60. This plan makes the work the user is waiting on go first, caps how much import work can be in flight, and shrinks the batch so new photos are noticed in seconds.

## Issues

## Phase 1 steps

1. **Add a priority to the task queue interface.** Extend `addTask` in `packages/task-queue/src/lib/queue-backend.ts` and `packages/task-queue/src/lib/task-queue.ts` with a priority argument. Two levels are enough: interactive (something the user is waiting on) and background (everything else). Default to background so no existing caller changes behaviour by accident. Update the `IQueueBackend` implementations: `packages/task-queue/src/lib/worker-queue-backend.ts`, `packages/mobile-frontend/src/lib/embedded-js-queue-backend.ts`, the Electron and WebSocket proxies, and the inline pool.

2. **Make the pending queue honour the priority.** In `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/EnginePool.java` and `apps/ios-frontend/ios/App/App/JsEngine/EnginePool.swift`, change the single pending FIFO so an interactive task is dispatched ahead of background ones while keeping arrival order within each level. Both `addTask` and `queueChildTask` feed the same queue, and child tasks must inherit their parent's priority so an import's children cannot jump ahead of a user's tap. Do the same for the desktop worker pools in `packages/node-api`.

3. **Reserve an engine for interactive work.** Even with priority, an interactive task still waits for a running background task to finish, and a hash of a large photo is not quick. In both engine pools, keep one engine that background tasks may not occupy while any interactive task is pending. Note that `asset-server` and `auto-import` each hold an engine for the life of the app, so the reservation must be counted against the engines that actually cycle.

4. **Mark the user-facing tasks interactive.** Tag the tasks raised in response to a tap: the database load path in `packages/user-interface/src/context/asset-database-source.tsx`, the databases-config reads in `packages/mobile-frontend/src/lib/mobile-databases-config-file.ts`, and the asset reads the gallery makes while scrolling. Everything automatic import raises stays background.

5. **Cap how many import children run at once.** `packages/node-api/src/lib/import-assets.worker.ts` queues a `hash-file` task for every file the scan finds, as fast as it can scan, then waits for them all. Add a concurrency limit so only a fixed number are in flight, queueing the next as each completes. The limit is 2 on mobile and 10 on desktop. Pass it in as task data from the caller rather than reading the platform inside the worker, so the worker stays platform-free and the limit is testable.

6. **Shrink the import batch.** The batch is up to 60 because the backfill rate is 60 items a minute and the budget is capped at one minute's worth (`packages/api/src/lib/auto-import-queue.ts`). Add an explicit maximum batch size, much smaller than 60, and apply it in `nextBatch`. Somewhere around 5 keeps the loop coming back to look for new photos every few seconds at the observed import rate. Leave the per-minute rate alone: it is the pacing, and the batch size is a separate thing that was never bounded.

7. **Look for new photos while a batch is running.** In `packages/api/src/lib/auto-import-loop.ts` the main loop only calls `collectArrivals` at the top, so nothing looks for new photos for as long as `importBatch` is awaited. Restructure so the arrival walk can run while a batch is in flight, or so a batch is interrupted when the watcher reports a change. The arrival walk itself lists every page of the library, which is 2,300 items on the test device, so it must not run more often than the watcher's poll interval.

8. **Put new photos in front of the backfill.** `nextBatch` already puts fast-lane items at the head of the batch. Once step 7 lets arrivals be found mid-import, make the next batch after an arrival carry the fast-lane items alone rather than filling the rest of the batch with backfill, so a photo just taken is imported next rather than behind up to a batch of old ones.

Every step must compile (`bun run compile`) and leave the unit tests passing before it is considered done.

## Phase 1 status: done, uncommitted, and partly superseded

Steps 1, 2, 4, 5, 6, 7 and 8 are implemented in the working tree and **not committed**. Nothing is to be committed until the whole of this plan is finished and reviewed.

What was verified, by running it: `bun run compile`; every unit test in every package; the 164 Android JVM tests; `bun run test:and` (45 of 45); `bun run test:cli`; `bun run test:electron` (36 of 36); and `test:cli:encrypted`, `test:cli:lan-share`, `test:cli:sync`, `test:cli:write-lock`, `test:cli:hash-cache`, `test:lan-share:cli-desktop` and `test:harness`. `bun run test:everything -- --force` has never passed as a whole, for the two reasons in "Two failing tests to fix as part of this work" below. The iOS changes have never been compiled: there is no macOS here.

Two decisions changed the plan as written:

- **Step 3, reserving an engine for interactive work, was dropped.** Reserving one drops background capacity from five engines to four, and four is exactly what the parents alone need when a manual import runs beside automatic import (asset-server, auto-import, and an `import-assets` for each), so every one of them would sit waiting for a `hash-file` child that could never get an engine. That is the silent deadlock the pool comment already warns about, one slot higher. The decision instead was to raise the pool and cap the import's children, which is what step 5 does.
- **The pending queue is one queue, not one per priority.** An interactive task joins the head, a background task joins the end, and the pool always takes from the head. Same on all three desktop pools and both native pools. The consequence, accepted deliberately: a second tap goes in front of a first one still waiting, so the most recent thing the user asked for is served first. Background work keeps its arrival order because it only ever joins the end.

**Two regressions phase 1 introduced, both from capping the batch at five, and both fixed by phase 3 rather than by reverting the cap:**

- The hash cache is saved once per `import-assets` run, and a run is now five photos instead of up to sixty, so cache saves became about twelve times more frequent. Each save is a full read-decode-sort-encode-rewrite of the whole file.
- Device cleanup runs after each batch on whatever that batch confirmed, and `SOURCE_CLEANUP_BATCH_SIZE` is 50, so it now issues a delete request per five photos instead of per fifty. On mobile every request is a system confirmation dialog: roughly four hundred dialogs for two thousand photos rather than forty.

The cap is not to be reverted: it is what stops the loop going blind for ten minutes at a time, which was the forty-two-minute photo. Phase 3 removes batching altogether, which removes both regressions with it.

**What phase 3 will undo from phase 1.** `MAX_IMPORT_BATCH_SIZE` and the fast-lane-alone batch rule are about batches and go when batching does; the lane behaviour they describe moves into `AutoImportScanner`. The task priority work and the import concurrency cap survive untouched and are central to everything below.

**Already done from phase 2:** step 1, the `isNewArrival` rename, is in the working tree. `isArrival` became `isNewArrival`, `collectArrivals` became `collectNewArrivals`, and a bug was fixed while doing it: the walk now runs beside the import, so the backfill can complete part way through a walk, and reading `queue.isBackfillComplete()` per item flipped the rule mid-walk and swept up the whole library a resumed cursor had already passed. It is now read once when the walk starts. The `auto-import.worker` test "resumes the backfill from a persisted cursor" caught it.

## Why each of these was decided

Recorded because the reasoning is not obvious from the change, and because it will be asked about later.

- **All platforms run the same code.** So that testing on the desktop exercises what a phone runs. The CLI is where this pays most: once automatic import is one scanner-driven task, `psi add --watch` covers most of it in seconds without an emulator.
- **The hash cache is keyed on the source id, not the file path.** A photo library item is not a file and has no path until it is copied, and the copy is the expensive thing the cache was meant to avoid. The key did not exist at the moment it was needed.
- **The timestamp check stays.** It was blamed for the cache missing on mobile and it is not the cause. Removing it would not fix mobile and would lose photos on desktop, where a file at a path can be edited in place and the check is the only thing that notices.
- **The asset id is recorded in the cache.** So "already imported" can be answered from the cache alone, without touching the database, which is what allows the check to happen before the photo is copied out of the library.
- **The cache is one per database.** A photo imported into two databases has two ids and one entry cannot hold both. Splitting is safer than a variable-length field in a fixed-width binary format, at the cost of hashing such a file twice. It has to land before the asset id is written, so it is a phase 2 step rather than a phase 3 one.
- **The cache format is not kept backward compatible.** Everything in it can be recomputed and the user can clear it whenever they like, so an old cache file is discarded rather than migrated. Bump the version and write no migration code.
- **Automatic import is folded into `import-assets`.** `import-assets` is built for one bounded job and amortises its scan, write lock, cache load and cache save over the whole of it. Automatic import invokes that whole apparatus per handful of photos.
- **The scanner does the pacing.** So `import-assets` never learns what a rate is: it asks for files and takes what it is given. This removed a step rather than adding one, and removed the need to choose a rate for manual import.
- **Runs are finite.** The end-of-run work then actually happens, and on mobile the engine slot is given back. Something has to restart a crashed task anyway, so the restart mechanism is not new work.
- **Device cleanup leaves the import entirely and becomes a button.** Every delete request raises a system confirmation, so the number of dialogs is decided by how deletions are grouped, and any grouping the import can manage produces tens or hundreds of them. One button, one dialog, when the user asks.
- **The cleanup toggle goes.** It turned automatic deletion on and off and there is no automatic deletion left.
- **`psi watch` is deleted.** It does not watch: it imports, syncs and exits. Its real purpose was to drive automatic import from the CLI, which `psi add --watch` does while being what it says.
- **No `--evict` on the CLI.** Dropping local originals is not a use case on a desktop machine, and a one-shot `psi sync` must never silently delete someone's files. The code path stays because the UI turns it on as a setting.

## Phase 1 unit tests

- `packages/task-queue/src/test/` — a task with interactive priority is dispatched before background tasks already queued; arrival order is kept within a priority; a child task inherits its parent's priority.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — no more than the configured number of hash tasks are in flight at once; every file is still hashed; the limit is read from the task data.
- `packages/api/src/test/lib/auto-import-queue.test.ts` — `nextBatch` never returns more than the maximum batch size; the per-minute pacing still holds across several calls; fast-lane items still come first.
- `packages/api/src/test/lib/auto-import-loop.test.ts` — an arrival reported while a batch is running is picked up without waiting for the batch to finish; the arrival walk does not run more often than the poll interval; the batch after an arrival carries the fast-lane items ahead of backfill.
- The native engine pools have no unit test framework in this repository. Cover them with the smoke tests below.

## Phase 1 smoke tests

- Android and iOS suites in `apps/smoke-tests/`: with a seeded library large enough to keep the import busy, open a database and assert the gallery is showing within a few seconds. This is the 2 minute 8 second failure and is the test that proves it fixed.
- Android and iOS suites: with the import running, add a photo to the device library and assert it reaches the gallery within seconds rather than minutes.
- `bun run test:cli` and `bun run test:electron`: the import concurrency limit does not slow the desktop import or drop files. Compare the imported count against the input count on an existing import test.

## Governing rule for all of this work: all platforms the same

Every part of import and automatic import runs the same code on every platform. Testing on the desktop must exercise as much of what a phone runs as it is possible to exercise, because the desktop is where this gets tested most and a divergence there is a divergence that nobody sees until it fails on a device.

A platform difference is allowed only where there are extreme mitigating circumstances, and then only when all three of these are true:

1. It is genuinely forced by the platform, not by convenience or by the shape of code that already exists.
2. It is confined to the smallest possible piece, with everything above and below it shared.
3. **It carries a comment in the code saying what the difference is, why the platform forces it, and what was considered instead.** Not in this plan, which is scratch and will be deleted: in the code, where the next reader is. Every decision here will be asked about later, and the comment is the answer.

The place this pays best is the CLI. Once automatic import is one scanner-driven `import-assets` task, `psi add --watch` runs the same code the desktop and mobile apps run, so the CLI smoke tests cover most of automatic import for every platform without an emulator or an Electron build. Keeping the CLI on the same code as the phone is therefore not tidiness, it is the difference between testing automatic import in seconds and testing it in minutes on a device.

There is exactly one difference known to be genuinely forced today, and it is already confined correctly: a photo library item is not a file, so mobile materialises a temporary copy through `openItem` and deletes it through `closeItem`, while a folder source hands over the file it already has. Everything above that contract is shared. Do not add a second one without meeting the three tests above.

Two differences that exist today and are NOT justified, and are to be removed by this work rather than preserved:

- **Restarting automatic import.** Mobile re-checks on a two second timer (`ensureAutoImport` in `platform-provider-mobile.tsx`), so a task that ends restarts within seconds. Desktop calls `ensureAutoImport()` only at startup and on a config change, and its completion handler never clears `autoImportRunning`, so an automatic import that ends for any reason stays dead for the rest of the session and `ensureAutoImport()` returns early believing it is still running. That is a live bug on desktop and it is also the mechanism the finite-run design below depends on, so both platforms need the same behaviour: notice the task has ended, clear the flag, start it again.
- **Where the watcher lives.** It has to be outside the task on every platform once a run is finite, not inside it on one and outside on another.

## Phase 2: stop re-doing work the app has already done

### What was measured, and what it says

Phase 1 made the app responsive during an import. It did nothing about the import repeating work it has already done. Five findings, each read out of the code rather than assumed:

1. **A path-keyed cache cannot work on mobile, because there is no path until after the expensive work is done.** `HashCache` is keyed by file path. A photo library item is not a file and has no path: `DeviceMediaSource.listPage` sets `filePath: ""` and says so in a comment. A path only exists once `openItem` has copied the item into the sandbox, which is the copy the cache was supposed to save, and `mediaLibraryClose` deletes it again afterwards. So the key does not exist at the moment it is needed.

   The timestamp check is a red herring and must not be touched. It does contribute to the miss (`mediaLibraryOpen` in `MediaLibraryHost.java` writes to a fresh `FileOutputStream` and never restores the original's timestamp, so each copy has a new modification time), but it is doing its job correctly: the temporary copy genuinely is a different file each time. Removing the check would not fix mobile and would lose photos on desktop, where a file at a path can be edited in place and the check is the only thing that notices. Fix the key, leave the check alone. This is the whole of "143 of 143 hashes computed from scratch".

2. **The cache does persist on a phone.** `getProcessTmpDir()` returns `os.tmpdir()`, and the mobile shim (`packages/mobile-worker/src/shims/node-os.ts`) returns the sandbox-relative name `tmp`. So the cache is at `tmp/photosphere/hash-cache-x.dat` inside the app sandbox and survives a restart. Nothing needs building to make it durable; it is durable and useless.

3. **Every item in a batch is copied out of the photo library before anything is asked about it.** `importBatch` in `auto-import-loop.ts` calls `source.openItem(item)` for every item in the batch and only then hands the paths to the import. A photo that is already in the database is copied in full, hashed in full, and then discarded. On a phone that copy is the most expensive thing in the loop.

4. **A stable identity already exists, and it is a different thing on each platform.** `IMediaItem.sourceId` is documented as not changing between listings, and it is already load-bearing: the backfill cursor is recorded in terms of it. The three implementations were checked rather than taken on the comment's word. A folder source uses the file's logical path (`folder-media-source.ts`). Android uses `MediaStore.Files.FileColumns._ID`. iOS uses `PHAsset.localIdentifier`. The listing also gives `size` and `createdAt` without opening anything.

   None of the three is stable forever, and the two failure modes are not equally safe:

   - **An id that changes** (a file moved or renamed on desktop, a MediaStore reindex, an iOS restore from backup) costs a cache miss and a re-hash. Harmless: the fallback is what happens today.
   - **An id that is reused for a different file** is the dangerous one. MediaStore ids are handed out again after a delete, so a cached entry could return the hash of a photo that no longer exists for a photo that has never been imported. If that hash happens to be in the database, step 4 would skip a photo that was never imported, and it would do so silently.

   The guard is that the identity is the **triple** (sourceId, size, createdAt), never the id alone, and all three must match before the cached hash is trusted. That is the same bar the cache already applies to paths today, where it requires size and modified time to match, so this is not a weaker guarantee than the one desktop already relies on. A recycled id landing on a file with an identical size and an identical creation time is what it would take to lose a photo.

5. **Nothing about "seen" survives a restart.** `AutoImportQueue.queuedSourceIds` is in memory, so after a restart the whole library is offered to the import again, and on mobile that means copying and re-hashing all of it.

### Opinion on making the hash cache the local-file to database-asset map

**Yes, and it is the smaller change of the two options.** The cache is already a durable path to (hash, size, modified time) map with merge-on-save under an exclusive lock, so several writers do not lose each other's entries. A second on-disk queue would need all of that built again. Four things have to be true for it to work:

- **Key it on the source item, not the file path.** On mobile the file path is the temporary copy and is worthless as a key. `sourceId` plus the listing's `size` and `createdAt` is the durable identity. On desktop the sourceId *is* the path, so desktop keeps behaving exactly as it does now.
- **The cache becomes one per database.** One cache serving every database on the machine is correct for hashes and wrong for asset ids: the same photo imported into two databases has two ids and one entry cannot hold both. Splitting the cache per database is the safe answer rather than making the entry carry a map of database to id, which would mean a variable-length field in a fixed-width binary format for the sake of a case that is rare.

  The cost is that a file imported into two databases is hashed twice. That is accepted: it is work, once, against a whole class of ways for one database's record to speak for another's.
- **It stays a performance optimisation, and the user can throw it away.** `psi hash-cache clear` already exists for exactly that. Losing the cache, whether by clearing it deliberately or by `/tmp` being emptied on a desktop reboot, costs work and never behaviour: photos it was speaking for are offered again, and the database's own hash index answers for every one of them exactly as it does today. Nothing about what is or is not in the database depends on the cache surviving.
- **The recorded asset id is treated as proof, and that is a deliberate decision.** If the cache says a photo was imported into this database, it is skipped without asking the database. That is what makes a photo deleted from the database stay deleted rather than being imported again on the next pass, which is the behaviour that was chosen. The cost is that the cache is now load-bearing for behaviour and not only an optimisation: if it is lost, every photo it was speaking for is offered again. It lives under a temp directory, so losing it is a thing that happens, and the consequence is a re-import rather than a loss of data.

**On recording the database asset id: it is recorded, and it is what decides the answer.** The id is allocated locally the moment we know a photo has to be imported, and written to the cache against that photo and that database. The check then reads it: an id present for this database means the photo is in, and nothing asks the database.

The reason is not speed, it is that the cache can answer without touching the database at all, which is what lets an already-imported photo be skipped before it is copied out of the photo library.

It is **not** what keeps a deleted photo deleted, and an earlier version of this plan said it was, wrongly. Deleting an asset sets `deleted: true` on its record; the record stays in the database and so its hash stays in the hash index, and `hashFileHandler` answers `filesAlreadyAdded` from that index without filtering on the flag. A deleted photo is therefore already not re-imported, with or without this cache. That behaviour works by accident rather than by design, which is what `plan-deleted-assets-record.md` is for.

Because a photo imported into two databases has two ids, the cache is split one per database, as above.

**On copying to a temporary file on every platform and moving it into the database: I recommend against it.** Three reasons, in order of weight:

- On desktop it makes things slower, not faster. Desktop imports read the user's own file in place. Copying every file to a temporary location first adds a full copy of every byte to a path that does not have one today.
- The move is not generally available. `upload-asset` writes through `IStorage.writeStream`, which is just as often S3 or an encrypting layer as it is local files, and a rename means nothing there. It would only work for plain unencrypted local storage.
- The source file has to survive until the thumbnail, display and micro derivatives have been generated from it, so a move can only happen at the very end, after the copy it was meant to replace has already been paid for in derivative generation.

The unification it was aiming for is already there: the import takes file paths and neither knows nor cares whether they are the user's originals or a temporary copy. Which of those it is, is the media source's business, and that is exactly what the `openItem` / `closeItem` contract says.

### Steps

1. **Rename `isArrival` to `isNewArrival`, and settle the words.** In `packages/api/src/lib/auto-import-loop.ts`. A file the loop has not seen before is a **new arrival**; one it has is **existing**. Use those two words in the code, the comments and the docs, and nowhere use "arrival" on its own to mean either.

2. **Make the hash cache one per database.** This has to land before anything writes an asset id into it, because an asset id means nothing in a cache shared by every database on the machine. Today the cache is at `<tmp>/photosphere/hash-cache-x.dat` and five places build that directory the same way: `import-assets.worker.ts`, `check.ts`, and the CLI's `hash-cache.ts`, `hash-cache-tools.ts` and `version.ts`.

   Keep the change to those five lines. Add one exported helper, `getHashCacheDir(databasePath)`, that returns the same directory with the database's identity appended, and have each of those places call it instead of joining the path themselves. `HashCache` itself does not change: it is still handed a directory and still writes `hash-cache-x.dat` inside it. `hashCacheDir` is already carried through the import as task data (`IHashFileData.hashCacheDir`), so the orchestrator works the path out once and everything below it is untouched. `version.ts` has no database in hand and keeps printing the parent directory.

   `psi hash-cache clear` takes no `--db` today and clears the one cache. Give it the same `--db` option `show` already has. Nothing else reads the cache.

   **Bump `HASH_CACHE_VERSION` from 1 to 2** in `packages/node-api/src/lib/hash-cache.ts` as part of this work, for the asset id field steps 4 and 5 add to the entry.

   **The hash cache is throwaway and has no backward compatibility to keep.** It is a performance cache and nothing else: every entry in it can be recomputed from the files themselves, and the user can delete the whole thing with `psi hash-cache clear` at any time without losing anything. So write **no** migration and **no** reader for any older format. Nothing new is needed to make that happen either: `decodeEntries` already compares the stored version against `HASH_CACHE_VERSION` with `!==` and returns undefined on any mismatch, and `load()` treats that as "start with a fresh cache" and logs it. That is exactly the behaviour wanted, and it does not need to be a "newer than" or "supported versions" check: not equal is discarded. Correct the wording of the two comments that call this an "unsupported version", because it is any version that is not this one. The per-database move above needs nothing at all: the old machine-wide `<tmp>/photosphere/hash-cache-x.dat` is simply never looked at again.

   Say this in a comment above `HASH_CACHE_VERSION`, so the next person to change the format bumps the number and stops, rather than writing a migration nobody needs.

3. **Carry a stable cache identity into the import.** Add a named interface `IFileCacheIdentity` to `packages/api/src/lib/import-assets.types.ts` carrying the whole triple: the source id as the key, the length, and the created time. All three are compared on lookup, for the id-reuse reason in finding 4. Add an optional `cacheIdentities` to `IImportAssetsData`, a map from the file path in `paths` to its identity. Only automatic import fills it in, from `IMediaItem.sourceId`, `size` and `createdAt`; every other caller passes nothing and is unchanged. A map keyed by path rather than a parallel array, because paths are unique within a batch and an index-aligned array is one reordering away from being silently wrong.

4. **Use the identity for the cache lookup and the cache write.** `getHashFromCache` in `packages/node-api/src/lib/hash.ts` takes an optional identity: when present it looks the entry up by `identity.key` and compares against `identity.length` and `identity.lastModified` rather than the file's own stat. `hashFileHandler` passes it through, and `import-assets.worker.ts` writes the entry back under the same key. With no identity, every path behaves exactly as it does today, which is what keeps desktop untouched.

5. **Ask the cache before copying anything out of the photo library.** This is the step that matters. The check reads the cache by source identity, requiring the id, the size and the created time to all match, and then:

   - **An asset id recorded for this database** means the photo is in. Skip it: no copy, no hash, no database lookup, no task.
   - **A hash but no asset id** means it was hashed but never imported here. Search the database's hash index for that hash, as the import does today, and skip it if it is there.
   - **No entry at all** falls through to the path that runs today: copy, hash, import.

   A skipped item still counts as `skipped` in the result. It is not recorded as anything for cleanup: cleanup answers its own question, as below.

   Load the hash cache **once** and reuse it for every item checked, rather than loading it per item. `HashCache.load()` reads and decodes the whole file, so loading per item would be quadratic in the size of the library and slower than the copying it replaces. No read lock is needed: `updateFileRawOptimistic` publishes by atomic rename, so a reader sees the old file or the new one and never a half-written one, and the checksum catches anything else. A copy that goes stale within a batch costs at most one recomputed hash: the entries it is missing are ones written moments ago by the import that is still running, and offering such a photo again is caught by the content hash.

6. **Drop cache entries whose source item is gone.** The arrival walk already reads every page of the listing, so it knows which source ids still exist. Remove the entries of the ones that do not, so the cache does not grow forever on a device where photos come and go. Do this only after step 5 is proven, and only in the walk that runs when the backfill is complete, so a partial listing never deletes entries wholesale.

7. **Later, and only once steps 1 to 6 have run on a device: replace the date heuristic with the cache.** With a durable per-item record, "new arrival" is simply "not in the cache", and `startedAtMs` and the `createdAt >= startedAtMs` comparison go away entirely, along with the whole class of bug where that comparison is made at the wrong moment. Worth doing, but it is a behaviour change to the backfill and does not belong in the same commit as anything above.

### Unit tests for phase 2

- `packages/api/src/test/lib/auto-import-loop.test.ts` — an item reported as already imported is never opened and never handed to the import, and is still counted; an item reported as not imported takes the existing path unchanged.
- `packages/node-api/src/test/lib/hash-cache.test.ts` — two databases get two different cache directories from `getHashCacheDir`, and the same database gets the same one every time; a cache file written by an older version is discarded rather than read.
- `packages/node-api/src/test/lib/hash-cache.test.ts` — an entry written under a source identity is found by that identity when the file path has changed underneath it; an entry is not returned when the identity's size or modified time differs; a lookup with no identity still matches on the file path exactly as before.
- `packages/node-api/src/test/lib/hash-file.worker.test.ts` — the identity is used for the lookup when present and the file's own stat when it is not.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — an identity supplied for a path is what the cache entry is written under.
- The already-imported check: an asset id recorded for this database skips without the database being asked at all; a hash with no id falls back to the database hash lookup; no entry falls through to the full import path.
- Each of these is to be watched failing before it is accepted, against the change it covers being reverted.

### Smoke tests for phase 2

- Android and iOS, the existing `47-auto-import` suite: import a photo, restart the app, and assert the second run does not re-import it and does not re-hash it. This is the test that proves the cache is being hit, and there is nothing like it today.
- `bun run test:cli` and `bun run test:electron`: unchanged counts on the existing import tests, which is what proves desktop was not disturbed.

## Phases 2 and 3 status: done, uncommitted

All of phase 2 and nearly all of phase 3 are implemented in the working tree and **not committed**.

What was verified, by running it: **`bun run test:everything -- --force`, all thirteen scripts passing**, which is compile, every unit test, all six CLI suites, the LAN share suite, the mobile harness, Electron (36 of 36), the 164 Android JVM tests and `test:and` (45 of 45). The Android suite ran on a single hand-started emulator, because the pool was down every time it was checked and starting it is not mine to do; with one device rather than five it runs its 45 tests one after another and takes 14 minutes. iOS has never been compiled or run: there is no macOS here.

### What was built

- The hash cache is one per database (`getHashCacheDir`), its format is version 2, and an entry now carries the asset id and a flag saying whether its key is a photo library source id rather than a file path. No migration: an unrecognised version is discarded and rebuilt.
- Automatic import asks the cache before opening an item, so a photo already in the database is never copied out of the library or hashed again.
- `auto-import` the task is gone. There is one `import-assets` task fed by an `IImportScanner`: `ManualImportScanner` walks a fixed list once, `AutoImportScanner` watches and paces. The desktop app, the mobile app and `psi add --watch` all run the same task.
- `AutoImportQueue.nextBatch` became `nextItem`: items come out one at a time, so the fast lane is looked at before every single import and `MAX_IMPORT_BATCH_SIZE` is gone.
- Cleanup is its own `cleanup-sources` task, driven by a button in the automatic import settings that counts first and deletes on a second press. The `cleanupEnabled` setting and its toggle are gone.
- `psi watch` is deleted. `psi add [--watch] [--cleanup]` and `psi sync --watch [--interval]` replace it, and smoke tests 81 to 84, 86 and 87 were moved onto them.
- **`psi add` and `psi add --watch` are one code path.** `addPaths` queues one `import-assets` task either way; `--watch` only decides whether the task data carries an `autoImport` request, which is what makes the scanner watch instead of walking the given paths once. There is no `--once`: a watch runs until it is interrupted, and a plain `psi add` is what a bounded run is. That is what makes `psi add` cover nearly all of the automatic import path, which is the reason for folding the two together in the first place.
- The desktop app restarts automatic import if it dies, which it never did before.

### Decisions made while building it, which need review

- **The engine pool size was not touched.** The plan says to decide it last, after measuring on a device, and nothing has been measured on a device. Automatic import now holds one engine rather than two, so the chain is shorter than the current `POOL_SIZE = 10` was sized for.
- **A run still does not end by itself.** The plan wanted finite runs restarted by the app, with the watcher moved out of the task. That needs the app to own a media source, which on mobile it cannot reach from the WebView. What landed instead: one task rather than two (so one engine rather than two), and the desktop restart logic. This is the one part of phase 3 deliberately left undone.
- **Eviction lost its smoke test coverage.** `psi watch --evict` is gone and nothing in the CLI triggers eviction, so `84-watch-sync-evict` became a watch-and-sync test. The eviction code path is unchanged and still has its unit tests.
- **Two bugs of mine, found by the smoke tests and fixed:** an `await` between an upload finishing and its database write being queued let a run end on top of the write, so the asset was uploaded and never recorded; and the import waited for `queue.awaitAllTasks()` alone, which reports the tasks done before their completion callbacks have recorded what they did.
- **The CLI sync suite was vacuous and is not any more.** It passed `<db>/metadata` where the collection root is `<db>/.db/bson`, so every one of its forty edits failed, the failure was tolerated, and it compared four databases nothing had modified. With the path fixed it exposed a second problem: `bdb edit` writes into the BSON database and never updates the content hash in `.db/state.dat`, and `psi sync` skips outright when both sides report the same hash, so the suite had never synced anything either. The suite now removes the stale state file after each raw edit. That is a workaround in the test, not a fix to the product: any writer that bypasses the application's stamping is invisible to sync.

## Phase 3: one import task, two scanners

Phase 2 keys the cache so it can be hit and moves the already-imported check before the copy. Phase 3 removes the reason the cache is expensive to keep in the first place: `import-assets` is torn down and rebuilt for every handful of photos.

### Why

`import-assets` was built for one bounded job: scan a folder, queue a task per file, hold the hash cache for the run, write the database under a throttled write lock, return a result. Everything in it is amortised over the whole scan.

Automatic import reuses that task by invoking it once per released batch, which was never a chosen size (it is whatever the pacing had released since the loop last looked). So the whole apparatus (scan, write lock, cache load, cache save) is paid per handful of photos rather than once. Capping the batch at five in phase 1 made that twelve times more frequent, which is how it was noticed.

The fix is to stop restarting the orchestrator. One long-lived `import-assets` task, fed by a scanner, is the shape manual import already has.

### What changes, and what must not

- **Arrivals become per photo for free; the progress counters do not.** Two different messages, and they are not in the same position.

  `import-success` is sent per asset by `import-assets` itself, and the gallery already listens for it: `asset-database-source.tsx` handles `import-success` and `auto-import-item` in the same branch. So an arrival reaching the gallery one at a time genuinely does fall out of deleting the batch layer.

  `auto-import-progress` does not. It is produced by the loop, not by `import-assets`, and `auto-import-progress.tsx` subscribes to it for the counters panel. Delete the loop and that message has no producer and the panel goes blank. The merged task has to emit it, derived from the per-file messages it already sends (`import-success`, `import-skipped`, `import-failed`), or the panel has to count those itself. That is real work, not something that falls out.
- **The file-processing core does not change.** One task per file, capped in flight, dedup by content hash, derivatives, throttled write-lock batching. That code is the most used and most tested in the app and this phase must not rewrite it.
- **The hash cache is owned by the orchestrator for its whole life.** One load at the start, a save every 100 newly hashed files, a save at the end. That is what it already does; it simply stops being restarted.
- **Pacing belongs to the scanner, not the orchestrator.** `import-assets` never learns what a rate is: it asks for more files and takes what it is given. `AutoImportScanner` withholds files until its budget allows; `ManualImportScanner` never withholds anything. So there is no rate in task data and no constant to choose for manual import.
- **Termination is the one genuine difference.** Manual import ends when its scanner is exhausted and returns a result that `psi add` and the Import page both await. Automatic import runs until cancelled.

### Steps

1. **Introduce the scanner, keeping the shape `scanPaths` already has.** A named interface `IImportScanner` with one method that takes the same per-file callback the import already passes to `scanPaths` and returns when there is no more to push. The scanner drives; the orchestrator is called back. This is deliberately the existing shape so the diff in `import-assets.worker.ts` is one line: the direct `scanPaths(...)` call becomes `scanner.scan(...)`.

   Nothing is needed for "nothing right now" or "exhausted": a paced scanner simply does not call back until its budget allows, and a finite one returns when its walk is done. That is what makes this the smallest change rather than a new protocol.

2. **`ManualImportScanner`** in `packages/node-api`, wrapping the existing `scanPaths` over a fixed list of paths. It calls `scanPaths` with the callback it was given and returns when it returns, so the orchestrator finishes and returns its result exactly as it does today. This is the path that must come out byte-for-byte equivalent, and the existing CLI and Electron import smoke tests are what prove it.

3. **`AutoImportScanner`** in `packages/node-api`, wrapping what `runAutoImportLoop` does now: the media source, the arrival walk, the backfill cursor and its persistence, the fast lane and the backfill lane, and the pacing. Its scan does not return until the task is cancelled; it pushes each file as the pacing releases it. It also owns `openItem` and `closeItem`, so the temporary copy stays the source's business and the orchestrator keeps taking plain paths.

4. **Fold the auto-import task into `import-assets`.** `auto-import` becomes a thin registration that builds an `AutoImportScanner` and queues `import-assets` once, or is removed entirely and the callers queue `import-assets` with the auto-import scanner named in its task data. One engine slot rather than two on mobile, which is a direct saving on the pool.

5. **Delete what the merge makes dead.** `runAutoImportLoop` and its per-batch invocation of `import-assets` go once step 4 lands. Nothing else should be deleted in the same commit.

### Automatic import ends when it has nothing left to do

A run is finite on every platform. When the scanner has nothing more to give and every file it gave has been imported, `import-assets` returns exactly as a manual import does, and the end-of-run work below happens because the end of the run is reached.

What restarts it is the app, not the task: the same logic that has to exist anyway for a task that crashed. Mobile already has it; desktop does not and must get it, as above. On mobile this also gives back the engine slot automatic import holds for the life of the app today, which is a direct saving on a pool of five.

The watcher moves out of the task and into the app, on every platform, since a finite run cannot own something that has to outlive it.

### Periodic flushing, in both modes

`import-assets` does three things only in the `finally` at the end of a run: writes the import record, removes the session temporary directory, and shuts the child queue down. With finite runs those are all reached, so this is no longer load-bearing. It is still worth doing, because the import record is already wrong today.

The import record is the one that is already wrong today, before any merge: it is written once at the end, so a manual import of two thousand photos that fails at nineteen hundred loses the record of all of them. It gets the same treatment as the hash cache in both modes: accumulate entries, flush every 100, flush again at the end. Each flush is a full read-modify-write of one JSON file, so the count matters for the same reason it does for the cache.

The session temporary directory is cleaned per file rather than per run, because the files in it are already removed as each import finishes with them; only the directory itself waits for the end.

### How this is kept safe

The size of the diff does not matter; how simple each change is to read does. A change that is simple and carries a comment saying why it is there is one that can be approved on sight. A clever one has to be explained and may be reverted, so prefer the obvious version every time.

There is one review at the end rather than a commit per step, so the order below is not about staging commits. It is about working in a sequence where each change can be tested before the next one lands, so a failure names the change that caused it:

- Steps 1 and 2 change nothing observable: the scanner is introduced and manual import is moved onto it. Green CLI and Electron import smoke tests are the proof.
- Step 3 introduces the auto-import scanner, pacing and all, without using it. Covered by unit tests alone, which are the existing pacing tests moved across.
- Step 4 is the only commit that changes automatic import's behaviour, and the Android `47-auto-import` smoke test is what proves it.
- Step 5 deletes only what is provably unreachable.

### Unit tests for phase 3

- `packages/node-api/src/test/lib/manual-import-scanner.test.ts` and `auto-import-scanner.test.ts` cover the two implementations; the interface itself has one method and no behaviour of its own to test.
- `packages/node-api/src/test/lib/manual-import-scanner.test.ts` — calls back for every file the scan finds, in scan order, and returns; an empty path list returns without calling back at all.
- `packages/node-api/src/test/lib/auto-import-scanner.test.ts` — the fast lane comes out ahead of the backfill, the backfill is paced by the scanner itself, the cursor is persisted and resumed, and the scan returns only when cancelled. These are the existing `auto-import-queue` and `auto-import-loop` tests moved onto the scanner, not new ones written from scratch.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — the orchestrator returns when a finite scanner returns; it keeps running against a scanner that only returns on cancellation; the hash cache is loaded once however many files pass through; the concurrency cap still holds across scanner refills; the import record is flushed part way through a long run and not only at the end, and a run that is cancelled after a flush keeps what was already written.

### Integration and smoke tests for phase 3

- `bun run test:cli` and `bun run test:electron`, unchanged, are what prove manual import survived. Every import test compares the imported count against the input count.
- The CLI `81-watch-once` through `84-watch-sync-evict` suites cover automatic import end to end on the desktop and must stay green through step 5.
- Android `47-auto-import` and `48-auto-import-no-permission` are what prove the merged task still works on a phone with the engine pool.
- One test that does not exist and should: import a photo, restart the app, and assert the second run neither re-imports nor re-hashes it. That is the test that proves the cache is doing its job, and it belongs with phase 2.

### Device cleanup comes out of the import entirely

Deleting imported photos from the device raises a system confirmation on both platforms, so the number of dialogs is decided by how deletions are grouped. Today `cleanUpConfirmedSources` runs after every import batch on whatever that batch confirmed, and `SOURCE_CLEANUP_BATCH_SIZE` is 50. Fifty was picked to avoid one dialog per photo; it is not a platform limit and nobody established what the ceiling is. Capping the batch at five in phase 1 made it worse again: cleanup only ever sees about five confirmed items, so it issues a request per five photos. Either way the count is unusable.

**The import task has nothing to do with cleanup.** It does not record cleanup candidates, does not load database hashes for it, and does not call it. All of that comes out: `cleanupCandidates`, `sourceIdByImportPath`, `cleanUpConfirmedSources` and the `loadDatabaseHashes` dependency leave `auto-import-loop.ts` with the rest of that file when phase 3 folds it in.

Cleanup becomes its own operation that answers its own question, and it needs nothing from the import to do so, because phase 2 already built the answer: walk the device library, and for each item ask the hash cache for its hash and the database whether it holds that hash. That is exactly `isAlreadyImported`.

**What it can and cannot see.** It offers a photo when this device's cache knows its hash and the database holds that hash. So a photo this device imported an hour ago is offered, where the old per-batch candidate list would have forgotten it. A photo imported on a different device and synced into the database is **not** offered, because this device never hashed it and the cache has no entry, and finding out would mean copying and hashing every photo in the library, which is the cost the whole plan exists to avoid. That is a real limit and it is the right trade: cleanup offers what it can prove cheaply, and the button says a count so the user can see what it found rather than being promised everything.

On mobile it is a button in the automatic import section of the configuration dialog (`packages/user-interface/src/components/auto-import-settings.tsx`). It says how many photos on this device are already in the database, and deletes them when tapped. One action, one dialog, at a moment the user chose.

**The cleanup toggle goes.** `auto-import-cleanup-toggle` and the `cleanupEnabled` setting behind it exist to turn automatic deletion on and off, and there is no automatic deletion left to turn on. The button replaces both: it is always there, it says what it would delete, and nothing is deleted without it being pressed. Remove the toggle from the card, the setting from `IAutoImportSettings`, and `cleanupEnabled` from the loop and its task data.

The rest:

- `selectConfirmedForCleanup` and `runSourceCleanup` in `packages/api/src/lib/source-cleanup.ts` are unchanged. Only what calls them, and what feeds them, changes.
- Whether one request can carry every pending item or has to be split is a platform question nobody has answered. Establish the real limit on Android and iOS before choosing a size, rather than keeping fifty because it is already there.
- The CLI has no confirmation dialog, so nothing there needs a button. `psi add --cleanup` stays as a flag, and runs the same walk the button runs, once, after the import finishes. That is the smaller change, it keeps `83-watch-cleanup` meaningful, and it keeps the deletion path shared: only what triggers it differs, and it differs because only mobile puts a system prompt in front of it. That difference gets a comment in the code, per the governing rule.

### Fold `psi watch` into `psi add --watch`, after phase 3

Do this after phase 3 and not before, because phase 3 is what makes it small. Today `addCommand` and `watchCommand` are separate implementations of the same job; once both are "queue `import-assets` with a scanner", they are the same call with a different scanner.

**Why this matters more than a tidier command line.** `psi watch` exists mainly so the automatic import task can be driven from the CLI. Once `psi add --watch` runs the same scanner-driven `import-assets` that the desktop and mobile apps run, the CLI smoke tests cover most of automatic import for every platform. That is the cheapest test path there is: no emulator, no Electron, seconds instead of minutes. Anything that makes the CLI path diverge from what a phone runs throws that away, so it is the governing rule above applied to the place it pays best.

The shape:

- **`psi add` gains exactly two flags: `--watch` and `--cleanup`.** Both default off, so `psi add <paths>` behaves exactly as it does today. That is the part that must not slip: `add` is the command people already use, and the existing CLI import smoke tests are what prove it is untouched.
- **`psi add --watch`** watches the folders and imports what appears. It knows nothing about the origin.
- **`--cleanup`** stays on `add` because it is genuinely coupled to importing: only a file just confirmed into the database is deleted.
- **`psi sync` gains `--watch`**, which watches the database and pushes to the origin as it changes. Run the two side by side and that is what `psi watch` does today, except each half is separately testable and separately useful, where today it is both or neither.
- **No `--sync` flag on `add`.** `psi sync` is already its own command; chain them.
- **No `--evict` flag anywhere.** Eviction is off for the CLI: dropping local originals is not a use case on a desktop machine where the CLI is used, and a one-shot `psi sync` must never silently delete someone's local files. The eviction code path stays exactly as it is, because the UI turns it on and off as a setting.
- **`psi watch` is deleted.** No alias.

The CLI smoke tests `81-watch-once` through `84-watch-sync-evict` cover the behaviour being moved and have to be rewritten onto the new commands as part of this, not left pointing at a command that no longer exists. `84-watch-sync-evict` is the one that changes meaning, since eviction is no longer something the CLI turns on.

### The engine pool size is decided here, once automatic import stops holding a slot

This moved from `plan-auto-import-quick-fixes.md`, which raised `POOL_SIZE` from 5 to 10 on the reasoning that two engines are permanently held. Phase 3 removes one of those two, so the two decisions cannot be made apart and the sizing belongs with the change that alters what holds a slot.

Do this last, after phase 3 has landed and been measured on a device, not before. What holds an engine after phase 3:

- `asset-server`, still for the life of the app. That one is unchanged.
- `import-assets`, for as long as a run lasts, which is now finite and idle most of the time.
- Its `hash-file` and `upload-asset` children, capped by `maxConcurrentTasks` from phase 1: two on mobile, ten on desktop.

So the deepest chain becomes the asset server, one import run and its two children: four, against five today, with automatic import no longer holding one of its own. Whether that needs 10, or needs nothing at all, is a measurement rather than an argument, and `docs/mobile-background-tasks.md` records that raising it costs about 28 MB of peak memory per slot on the device that is already the most likely to be killed for memory.

Whatever is decided, both constants change together and both comments are rewritten to describe the chain as it then is: `EnginePool.java` and `EnginePool.swift` each spell the chain out slot by slot today, and those comments go stale the moment phase 3 lands. `docs/mobile-background-tasks.md` says the same thing in prose and needs the same treatment.

## Two failing tests to fix as part of this work

Neither is caused by this plan's changes, and both are this plan's job anyway.

1. **The CLI sync suite's edit step has never worked.** `apps/cli/sync-smoke-test.sh` calls `bdb edit "$db_path/metadata" metadata ...`, passing `<db>/metadata` as the database path. The collection root is `<db>/.db/bson`. Confirmed by running both against a real database from a previous run: the current path answers `Record ... not found in collection 'metadata'`, and `<db>/.db/bson` answers `Successfully updated field 'description'`. Every one of the suite's forty iterations fails this way, the failure is tolerated with a `continue`, and the suite then passes because it compares four databases that nothing ever modified. So it is a vacuous test in the sense `docs/plans/done/plan-audit-vacuous-tests.md` means.

   **Fixed, and it exposed a second problem.** With the path corrected the edits land, and the suite immediately failed for real: the four databases ended on four different values for the same field. The cause is that `bdb edit` writes straight into the BSON database and knows nothing about the state file one level above it, where the application records the database's content hash. `psi sync` reads that hash first and skips outright when both sides report the same one, so an edit made that way is invisible to it and the suite had never synced anything at all.

   The suite now deletes the state file after each raw edit, which is how a raw write says "what is recorded about me is no longer true"; the next write recreates it. **That is a workaround in the test, not a fix to the product**, and it is worth saying plainly what it leaves standing: sync's fast path trusts a stamp that only the application maintains, so any writer that bypasses the application is invisible to sync. Nothing the application itself does bypasses it, because every write it makes stamps the hash as it goes.

   With that, the suite does what it claims: four processes editing and syncing the same asset concurrently, ending on one root hash.

2. **`test:and` cannot start under `test:everything`.** It refuses below `PHOTOSPHERE_MIN_AVAILABLE_MB` (4096) and sees about 2GB, because `scripts/test-everything-parallel.sh` starts twelve lanes at once on a machine already holding five emulators. It passes when run on its own. The floor itself is right and is not to be lowered: it exists because stacking the Android suite against other lanes killed all five pool emulators on 2026-08-09.

   **Measured, and it points at the pool rather than the lanes.** `bun run test:everything -- --force` was run with one hand-started emulator attached and no pool: all thirteen scripts passed, `test:and` among them, and with all twelve lanes running there was 13.6GB available against the 4096MB floor. So twelve lanes on their own leave the Android suite plenty of headroom.

   That leaves the five pool emulators as the load that pushes it under, which fits the numbers already recorded here: five of them hold 6.0 to 8.0GB between them. It is not proven, because the failing case has not been reproduced since: it needs the pool up, and bringing it up is not mine to do. What is now worth measuring is the pool up and idle, then the same run beside it, rather than the lane count.

   Also run: the 164 Android JVM unit tests, which need no device, and the 45 Android smoke tests on the single attached emulator.

## Last step: update the wiki

Do this last, once everything else is settled and reviewed, so it describes what shipped rather than what was intended. The wiki is a separate checkout (`photosphere.wiki`, the second working directory), and it is what users read: it is the only documentation that is wrong in front of somebody who has not seen this plan.

What this work changes there:

- **`Command-Reference.md`, the `add` entry.** It gains `--watch` and `--cleanup`, and its argument becomes optional, because `psi add --watch` with no paths watches the operating system's own photo folders. The examples should show the watching form beside the one-shot form.
- **`Command-Reference.md`, the `sync` entry.** It gains `--watch` and `--interval <seconds>`.
- **`Command-Reference.md`, the `watch` entry, if there is one.** `psi watch` is deleted. There is no alias and no deprecation: the entry goes, and the two commands that replace it are named in its place so somebody searching for it lands somewhere useful.
- **`Command-Reference.md`, the `hash-cache` entry.** Already rewritten during this work for `--db` and the one-cache-per-database rule. Check it still matches at the end rather than assuming.
- **Anywhere the automatic import settings are described.** The cleanup toggle is gone and a button replaced it, which counts first and deletes on a second press.

What to check rather than assume: `grep -rn "psi watch" *.md` in the wiki checkout came back empty when this was written, so there may be nothing to delete. `How-It-Works.md` mentions automatic import only in a diagram label, which is still accurate.

Nothing in the wiki is committed or pushed as part of this work without being asked for: it is a separate repository with its own history.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes, including the two suites it once could not: the CLI sync suite, whose edit path is fixed, and the Android suite. Both now pass. **Done: all thirteen scripts passed.**
- The wiki is brought up to date, as the last step above.

On a device, with a library large enough to keep the import busy:

- A database opens in seconds while an import is running, and a photo taken with the camera appears in the gallery within seconds. That is phase 1, and it is what the whole plan started from.
- Restarting the app does not re-copy or re-hash photos already imported. That is what proves the cache is being used, and there is no test for it today.
- The device cleanup button says a sensible count, and deleting is one confirmation rather than one per batch.
- A photo deleted from the database is not imported again on the next pass.

## Notes

- The three causes are separate and each is enough to cause the delay on its own: unbounded child tasks filling the queue, no priority so a tap sits behind them, and a batch large enough that the loop is blind to new photos for ten minutes at a time. Fixing one and not the others will not give the result.
- Measured during testing: 143 of 143 hashes computed from scratch, 5 engines with 2 permanently held, batches of 50 to 60, and an import rate of about 5 photos a minute. The hash cache is a separate plan and fixing it will raise the import rate, which shortens a batch but does not remove the need for priority.
- Steps 1 to 3 change a shared interface and both native pools, so they touch desktop as well as mobile. Desktop has more workers and a faster disk and does not show the problem, but the same code paths are used and must keep working.
- The two open questions that were here about step 3 and step 7 are answered: step 3 was dropped, and the arrival walk runs alongside the batch rather than interrupting it. See the phase 1 status above.

## How to work on this

- **Nothing is committed until the whole plan is finished and the human has reviewed it.** There is one review at the end.
- **The size of the diff does not matter. How simple each change is to read does.** A simple change with a comment saying why it is there gets approved on sight. A clever one has to be explained and may be reverted. Prefer the obvious version every time.
- **Every decision here will be asked about later, so record the intent as a comment in the code**, not in this plan. Plans are scratch and get deleted; the comment is what the next reader has.
- **A platform difference needs a comment saying what it is, why the platform forces it, and what was considered instead.** See the governing rule above.
- Work in an order where each change can be tested before the next lands, so a failing test names the change that caused it.
