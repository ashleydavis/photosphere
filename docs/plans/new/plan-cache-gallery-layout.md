# Cache the computed gallery layout so it comes back instantly

## Overview

Every time the gallery is opened the app rebuilds it from nothing: `load-assets` walks the sort index a page at a time, each page is fed to `computePartialLayout` in `packages/user-interface/src/lib/create-layout.ts`, and rows, offsets and the gallery height are computed again from scratch. Nothing about that work changes between one open and the next unless the photos, the sort, the search, the row height or the screen width change, and on a phone the screen width never changes at all. So the whole result can be kept: the rows with their offsets and heights, and for each item the handful of fields the gallery draws with, including the micro thumbnail that is already carried on every record. Restoring that is a file read and a deserialisation rather than a walk of eight thousand records, which is the difference between a gallery that is there when the app opens and one that assembles itself while the user watches. The cache is per device and per database, it lives beside the hash cache and the import record in the per-database cache directory, and it is keyed by everything the layout depends on, so a cached layout is either exactly right or not used.

## Issues

## Steps

1. **Measure what is being replaced.** Before any caching exists, record how long the current path takes on the Pixel 6 against a database of about eight thousand photos: time to the first row painted, time to the last page, and the time `computePartialLayout` itself accounts for across the whole load. Write the numbers into `docs/performance/gallery-load-before-and-after.md`, creating it if `plan-instant-invisible-asset-load.md` has not already. Without them there is no way to say whether the cache is worth its complexity, and a cache that is not faster is pure liability. This step changes no behaviour. Compile and tests pass.

2. **Define what is cached and how it is keyed.** Add `packages/user-interface/src/lib/gallery-layout-cache-key.ts` exporting a pure function that builds the key a cached layout is stored and looked up under, from: the database's content hash (the value the state file already holds, which moves whenever anything in the database changes), the sort, the search text (empty for the unfiltered gallery), the gallery width in pixels, and the target row height. Two layouts differing in any of those are different cache entries, and a key that cannot be built (no content hash yet) means no caching for that open. Unit test every part of the key contributing to it and the missing-content-hash case. Compile and tests pass.

3. **Define the serialised form.** Add `packages/user-interface/src/lib/gallery-layout-cache-format.ts` with the interface for a cached layout and pure functions to serialise and deserialise it. Requirements:
    - It holds the rows in order, each with its offset, height, width, type and heading, and each item with only the fields the gallery draws with, which is the same whitelist `loadAssetsHandler` already applies plus the micro thumbnail.
    - The micro thumbnail is a base64 string on the record (`IAsset.micro`), and it will dominate the file. Store it as bytes rather than as base64 text, and decode to a data URI on load, or measure and prove that keeping it as text is not worth avoiding.
    - Serialisation and deserialisation are pure functions over data, with no filesystem and no platform API, so they can be unit tested and so the mobile worker can use them.
    - The format carries a version number, and a file whose version is not the one this build writes is ignored rather than migrated. A layout cache is disposable by definition: getting it wrong must never be able to show the user a stale or corrupt gallery.
    Unit tests: a round trip preserves every field, a truncated file fails cleanly, an unknown version is refused, and an empty layout round trips. Compile and tests pass.

4. **Store it beside the other per-database caches.** The layout file goes in the directory `getDatabaseCacheDir` in `packages/node-api/src/lib/database-cache-dir.ts` already returns, next to `imports.dat` and `hash-cache/`, with one file per cache key. Add the path helper there beside `getImportRecordPath`, and a storage module that reads and writes the file and prunes entries that are no longer the current key, so the directory does not grow a file per screen width the device has ever had. Unit tests for the path helper, the read of a missing file (which reads as no cache rather than throwing), and the pruning. Compile and tests pass.

5. **Reach the cache from the interface.** The gallery runs in the WebView, which on mobile cannot touch the filesystem, so reading and writing this file has to go through a background task, the way `read-databases-config` and `write-databases-config` already do for `databases.toml`. Add the two task handlers, register them for every platform, and have the desktop call the same tasks rather than growing a second path. **Measure the round trip before building anything on top of it**: a task queued into the engine pool competes with the very work this is meant to make instant, and if fetching the cache costs more than a second the file is in the wrong place and the fallback is the WebView's own IndexedDB. Record the measurement beside step 1's numbers. Unit tests for both handlers. Compile and tests pass.

6. **Paint from the cache when a database is opened.** In `packages/user-interface/src/context/asset-database-source.tsx` and `gallery-context.tsx`, look the cache up as the database is opened, before `loadAssets` is queued, and if there is a hit for the current key, install that layout and paint. The load still runs behind it: what it returns replaces the cached layout when it completes, so a cache that is subtly wrong is corrected within the same open rather than persisting. React contexts get no unit tests; the smoke tests below cover this.

7. **Write the cache when a layout is complete.** When a load finishes and the layout is final, serialise and store it under its key. Write it once per completed load rather than per page, so a load that is cancelled or fails writes nothing. Unit test the decision of when to write as a pure function (given a load outcome and a key, write or not).

8. **Keep new photos out of a full rebuild.** Photos imported or synced after a layout was cached change the database's content hash, which invalidates the key and throws the layout away, which is correct and wasteful: a phone importing all day would never get a cache hit. Add the narrower path: when the cached layout's content hash is an ancestor of the current one and the only difference is items added at the front of the sort order, extend the cached layout with those items rather than discarding it. `computePartialLayout` already takes an existing layout and extends it, which is the function to reuse. Anything that is not purely an addition at the front (a deletion, an edit, a reorder) falls back to a rebuild. Unit tests for the decision function: additions extend, deletions rebuild, edits rebuild, a changed sort rebuilds.

9. **Cache the other sorts and the saved searches.** Each sort order is its own key and so is cached separately by construction once step 2 is in: confirm that changing the sort with both layouts cached switches instantly, and that nothing rebuilds. Then warm the saved searches (`savedSearches` in `config.yaml`) in the background after the main layout is cached, so opening a saved search is a cache hit too. Warming is background priority and must never delay an interactive load. Unit test the warming decision (which keys to warm, and not warming when the database has changed underneath).

10. **Invalidate on the things that are not the database.** The row height (`galleryRowHeight`) and the gallery width both feed the key, so a change to either misses the cache and rebuilds, which is correct. Confirm that with a test rather than by reading the key builder, because this is the case that would show the user a layout computed for a different screen and it is the worst failure this feature can have.

11. **Write the documentation.** Add a section to `docs/development.md` or a new document under `docs/performance/` covering: what is cached, where the files live, what invalidates them, what happens on a miss, and the measurements from steps 1 and 5 showing what it bought. Note in `docs/automatic-photo-backup.md`'s description of the per-database cache directory that the layout cache is now one of the things in it.

## Unit Tests

- The cache key builder (`packages/user-interface/src/test/lib/gallery-layout-cache-key.test.ts`): every input changes the key; the same inputs give the same key; a missing content hash yields no key.
- The serialiser and deserialiser (`packages/user-interface/src/test/lib/gallery-layout-cache-format.test.ts`): full round trip including headings and micro thumbnails, an empty layout, a truncated file, an unknown version.
- The path helper and storage module (`packages/node-api/src/test/lib/`): the path for a key, a missing file reading as no cache, pruning entries whose key is not current.
- The two task handlers: read returns what write wrote, and a read of nothing returns nothing rather than throwing.
- The write decision (step 7) and the extend-or-rebuild decision (step 8), each as pure functions with a case per outcome.
- The warming decision (step 9).
- No unit tests for the gallery components or contexts: covered end to end.

## Smoke Tests

- Mobile: open a database with a seeded layout cache and assert the first row is painted before the load's first page message arrives.
- Mobile: open a database twice, and assert the second open paints from the cache and the first does not.
- Mobile: import a photo, reopen, and assert the gallery shows it (the extend path in step 8) rather than showing a stale layout.
- Mobile: change the sort with both sorts cached and assert no rebuild is queued.
- Desktop: resize the window across a row-height boundary and assert the layout is rebuilt rather than restored, which is the invalidation that matters most.
- `bun run stories:and` renders the gallery at phone resolution unchanged.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- The measurements in `docs/performance/gallery-load-before-and-after.md` show a second open of an eight thousand photo database painting its first screenful in a fraction of the time step 1 recorded, with the cache read cost stated separately.

## Notes

- **The cache is a picture of a computation, not of the database.** Everything in it can be recomputed from the database, so it is safe to delete at any time, which is what makes the per-database cache directory the right home: the platform, a backup tool and a disk cleaner all treat that location as disposable.
- **Correctness comes from the key, not from patching.** Every input the layout depends on is in the key, so a hit is exactly right and anything else is a miss. The one place that rule is bent is step 8's extension for added items, which is why its decision function is a pure function with its own tests rather than a condition buried in a context.
- **The micro thumbnails dominate the file.** They are base64 strings on the record today, and base64 costs a third more bytes than the image it encodes. Storing them as bytes is the difference between a cache that loads quickly and one that is its own performance problem, which is why step 3 requires either that or a measurement proving otherwise.
- **The mobile round trip is the real risk.** The WebView cannot read the file itself, so every cache hit costs a task through the engine pool, and the pool has three slots with one permanently held by the asset server. If that round trip is slow the whole idea is defeated, which is why step 5 measures it before anything is built on top of it, and why IndexedDB is named as the fallback rather than discovered later.
- **A phone that is importing invalidates the cache constantly.** Automatic import commits every 250 photos, and each commit moves the database's content hash. Without step 8 a phone backing up its library would never see a cache hit, which is exactly the phone that needs one.
- **This overlaps `plan-instant-invisible-asset-load.md`**, which caches the first screenful of records for the same reason. If both are built, this one supersedes that plan's cache: a cached layout is a superset of a cached first page. Decide which is being built before starting either, rather than building two caches of the same thing.
