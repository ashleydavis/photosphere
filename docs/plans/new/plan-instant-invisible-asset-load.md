# Make loading the gallery instant and invisible

## Overview

Opening the app on a database of eight thousand photos shows an empty screen, then a count that ticks upwards, then a scrollbar that keeps changing size as pages arrive, and a job in the jobs list telling the user about work they should never have had to know was happening. Turning the screen off and on again does the whole thing again from blank. The cause is that the gallery is built entirely from what has streamed in so far: `loadAssetsHandler` in `packages/node-api/src/lib/load-assets.worker.ts` walks the sort index a page at a time and sends each page as an `asset-page` message, the frontend appends each batch, and the count, the layout and the scrollbar are all derived from the items that have arrived. Nothing is remembered between runs and nothing is known up front, so every start pays the full cost with the user watching. The database already knows how many photos it holds before a single record is read, and the app already keeps per-database state on disk, so both of the things the user is watching for (the total, and the first screenful) can be there immediately. This plan measures the current behaviour first, then fixes it in that order: instant count, instant first page, correct scrollbar, fast remainder, no visible job, and a return from a blank screen that is not a cold start.

## Issues

## Steps

1. **Measure before changing anything.** Add timing to `loadAssetsHandler` and to the frontend's load path in `packages/user-interface/src/context/asset-database-source.tsx` reporting, as log lines: time from the load starting to the first `asset-page` reaching the interface, time to the first page being painted, time to the last page, the number of pages, and the records per page. Run it against a real database of about eight thousand photos on the Pixel 6 over adb and record the numbers in a new `docs/performance/gallery-load-before-and-after.md`, following the shape of `docs/performance/native-hashing-before-and-after.md`. Every later step is judged against these numbers, and without them "faster" is an opinion. **This step changes no behaviour.** Compile and tests pass.

2. **Show the true total immediately.** The count the navbar shows is the number of items loaded so far, which is why it climbs. The database's own total is in the merkle tree metadata and is what `getDatabaseSummary` already returns as `totalImports` from a single small read. Have the frontend read that when a database is opened, before any page arrives, and show it as the photo count, with the loaded-so-far count used only where the code genuinely means "how many do I have in memory". Unit test the selection rule as a pure function: given a known total and a loaded count, which is displayed. Compile and tests pass.

3. **Size the layout for the whole database from the start.** `computePartialLayout` in `packages/user-interface/src/lib/create-layout.ts` builds rows from the items it has been given, so the scroll height grows as pages arrive and the scrollbar jumps. Extend it to take the expected total and to reserve space for the items not yet loaded, so the scroll height is right from the first paint and does not change as pages arrive. Rows of unknown items are reserved at the target row height, which is what the gallery already uses as its per-row target, and are replaced by real rows as the items arrive. Unit tests for the new behaviour: the height with nothing loaded, the height part-way through, that the height does not change when a page arrives, and that scrolling into a reserved region shows placeholders rather than nothing. Compile and tests pass.

4. **Remember the first screenful between runs.** Persist enough of the gallery to paint immediately at the next start: the first N records in sort order, where N covers a screenful at the largest phone size, written to the per-database cache directory (`getDatabaseCacheDir`, the same place the hash cache and the import record live, described in `docs/automatic-photo-backup.md`). Write it when the first page arrives; read it when a database is opened, before the load starts, and paint from it. It must be invalidated when the database's content hash changes, which the state file already holds, so a stale first page is impossible rather than unlikely. New functions get unit tests: what is written, what is read back, and the invalidation. Compile and tests pass.

5. **Make the load invisible.** Add an optional flag to `IJobTag` in `packages/task-queue/src/lib/types.ts` marking a job as not shown, have `applyJobProgress` in `packages/user-interface/src/lib/jobs.ts` keep it out of the list the navbar indicator and the jobs dialog read, and set it on the tag `loadAssets` builds in `packages/api/src/lib/load-assets.ts`. Add a developer setting that shows hidden jobs anyway, alongside the existing developer-only settings in `packages/user-interface/src/pages/developer.tsx`, stored as a config key beside `showFpsIndicator`. Unit tests for the filtering, both ways. Compile and tests pass.

6. **Remove the second indicator this reveals.** The navbar's "Loading" spinner is a separate duplicate of the same information and is covered by `plan-remove-duplicate-loading-indicator.md`. Do that plan first or fold its single edit in here, but do not leave a state where the job is hidden and the spinner still announces the load.

7. **Find out why a return to the screen is a cold start, then stop it.** On Android the activity declares `configChanges` for orientation and friends but the WebView can still be destroyed when the app leaves the screen (`docs/mobile-background-tasks.md` describes the engine pool being torn down for exactly that reason), and a destroyed WebView means the interface starts from nothing: `notifyDatabaseOpened` runs again, `loadAssets` starts again, and the user watches the whole load a second time. Establish which of the two it is by instrumenting the app's startup path and reading `adb logcat` around a screen off and on, rather than assuming. Then fix what the evidence says: if the WebView survives, the reload is the interface's own doing and steps 2 to 4 already cover the symptoms; if it does not, the first paint has to come from the cache in step 4 and the reload has to be incremental rather than starting from an empty gallery. Record the finding in the performance doc from step 1.

8. **Speed up the streaming itself.** With the measurements from step 1 in hand, look at what the load actually spends its time on: the page size the sort index returns, the per-record fields sent (the handler already excludes EXIF for a documented reason), the cost of the structured clone per batch, and how many batches the interface re-renders for. Change one thing at a time and re-measure against step 1's numbers, recording each in the performance doc. Do not change several at once: a combined change that helps overall can hide one that made things worse.

9. **Update the documentation to match the code**, including the final measurements, which is the whole point of having taken the first set. The documents affected are `docs/background-tasks.md` (the invisible job) and a new section under `docs/performance/` describing what the gallery does on open.

## Unit Tests

- The display-count rule (new pure function, in `packages/user-interface/src/lib/`): shows the database total when known, the loaded count when not, and never a total smaller than the loaded count.
- `computePartialLayout` (`packages/user-interface/src/test/lib/create-layout.test.ts`): height with an expected total and nothing loaded; height unchanged as pages arrive; placeholders in the reserved region; the existing tests still pass unchanged when no total is given.
- The first-page cache (new module): what is written, what is read back, invalidation on a changed content hash, and a missing or unreadable cache reading as "nothing cached" rather than throwing.
- `applyJobProgress` and the indicator and list selectors in `packages/user-interface/src/lib/jobs.ts`: a hidden job is excluded, and included when the developer setting is on.
- `loadAssetsHandler` (`packages/node-api/src/test/lib/load-assets.worker.test.ts`): the existing tests plus whatever step 8 changes about paging.
- No unit tests for the gallery components, the navbar or the developer page: React components are covered end to end.

## Smoke Tests

- `apps/smoke-tests/tests/3-open-database`: the photo count shows the database's real total before every page has arrived, and does not change as the rest load.
- A new mobile test: with a seeded database, open it, background the app, bring it back, and assert the gallery paints from the cache without a full reload (asserted by the first paint happening before the load's first page message).
- `apps/smoke-tests/tests/35-database-summary` and the jobs coverage: no job row for loading assets appears, and one does appear when the developer setting for hidden jobs is on.
- Desktop equivalents beside the existing job manager coverage.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- The measurements in `docs/performance/gallery-load-before-and-after.md` show, on the same device and the same database as step 1: a first paint that does not wait for the load, a photo count that is correct at the first paint, a scroll height that does not change while loading, and a shorter time to the last page than before.
- `bun run stories:and` renders the gallery at phone resolution with no visible loading job.

## Notes

- **Measure first is not a formality here.** The user's complaint is about how long things take, and there is no record anywhere of how long they take. Steps 3 to 5 change what the user sees rather than what the machine does, and without numbers there is no way to tell whether step 8 helped or whether the app only felt faster because it stopped showing the wait.
- **The total is cheap and already computed.** `getDatabaseSummary` reads the merkle tree and returns `totalImports`, which is the number the navbar should show from the first moment. Nothing new has to be counted.
- **The reserved-space layout is the part most likely to look wrong.** Photos are laid out by aspect ratio into rows of a target height, so space reserved for unknown items can only assume an average, and the scrollbar will shift slightly as real items replace assumed ones. The requirement is that it does not jump, not that it is exact to the pixel, and the unit tests should assert stability rather than exactness.
- **The cache is a convenience, not a source of truth.** It holds a screenful of records to paint immediately and is thrown away whenever the database's content hash moves. Nothing may be shown from it that the load then contradicts, which is why the invalidation is tested rather than assumed.
- **The screen-off reload may not be the interface's fault at all**, which is why step 7 measures before it changes anything. If Android is destroying the WebView, no amount of frontend caching removes the restart; it only makes the restart invisible, which is what the user is actually asking for.
