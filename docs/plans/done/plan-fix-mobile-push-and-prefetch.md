# Make a phone able to push what it imports, and to finish filling in a replica

## Overview

Measuring a Pixel 6 against a partial replica of a database of 8,231 photos found that a phone takes photos in perfectly well and then cannot get a single one off the device, and that the prefetch which is supposed to fill the replica in dies part way and is never started again. The evidence is in `docs/performance/mobile-sync-at-scale.md`. This plan fixes the three things that stop that flow working: every S3 upload from an encrypted database goes through the AWS SDK's multipart uploader and the multipart uploader cannot read the mobile stream shim; the prefetch copies each file under a thirty second deadline that its own database index files cannot meet; and a prefetch only ever runs when a database is opened, so one that fails stays failed. It also adds the end to end test that would have caught the first of these, which the existing mobile suite misses because its fixture is a few kilobytes.

Nothing here reports a failure to the user. A file that will not copy is already retried on the next pass, which is the right behaviour once the copy can succeed, and an error a user cannot act on is noise.

## Issues

<!-- Populated later by plan:check -->

## Steps

Each numbered step below is one commit. Within a step the executing agent writes the code and its tests, watches the new tests fail before the fix and pass after it, then follows the **Commit and prove** procedure at the bottom of this section before starting the next step. Do not start a step while the previous step's workflow run is still red or still running.

### 1. Make an encrypted database's uploads reach S3 from a phone

**The diagnosis, already established, which the agent should confirm before changing anything.** On an encrypted database `EncryptedStorage.writeStreamHashed` in `packages/storage/src/lib/encrypted-storage.ts` cannot hand the plaintext hash down to the store, so it delegates to `EncryptedStorage.writeStream`, which pipes the caller's stream through `createEncryptionStream` and passes the result to `CloudStorage.writeStream` in `packages/storage/src/lib/cloud-storage.ts`. `CloudStorage.writeStream` always uses `new Upload(...)` from `@aws-sdk/lib-storage`, so **every** upload from an encrypted database takes the multipart path regardless of size, and none of the single request reasoning behind `SINGLE_PART_MAX_BYTES` applies to it. `lib-storage`'s chunker then async iterates the body (`getDataReadable` calling `for await ... of`), and `createEncryptionStream` returns a `Transform` from `packages/encryption/src/lib/encrypt-stream.ts`, which on mobile is the shim `Transform` in `packages/mobile-worker/src/shims/node-stream.ts`. That shim's `Transform` is a plain function with a hand built prototype carrying `on`, `once`, `emit`, `push`, `write`, `end`, `pipe`, `destroy` and `scheduleDrain`, and **no `Symbol.asyncIterator`**. It also does not extend the shim's `Readable`, which does have one. So the chunker calls `undefined` and the upload fails with `not a function`, on every original, for ever.

Confirm that reading before changing it: check that `transformPrototype` has no `Symbol.asyncIterator`, and that `Readable` at line 259 of the same file does.

**The change.** Give the shim's `Transform` prototype an async iterator with the same contract as the shim's `Readable` one: yield each `Buffer` pushed through the transform, in order, and finish when the transform ends. It has to work whether the consumer starts iterating before or after bytes arrive, because the existing prototype already buffers output in `shimPending` until a `data` listener attaches and the same buffering has to feed the iterator. Reuse the existing listener and drain machinery rather than adding a second delivery path: the simplest correct implementation attaches `data`, `end` and `error` listeners and turns them into the iterator's yields, completion and rejection.

Do not change `CloudStorage.writeStream` to avoid the multipart path. The bug is that the shim cannot be read, not that the multipart path is wrong, and a phone still needs a working multipart path for a file over `SINGLE_PART_MAX_BYTES`.

Files:

- `packages/mobile-worker/src/shims/node-stream.ts`: add `transformPrototype[Symbol.asyncIterator]`.
- `packages/mobile-worker/src/test/shims/node-stream.test.ts` (create if absent, otherwise extend): the unit tests listed under Unit Tests.
- `apps/smoke-tests/tests/56-large-asset-push/test.sh` (new): the smoke test listed under Smoke Tests.

The smoke test is what proves this on a device, and it must be written and watched failing before the shim is changed.

### 2. Let the prefetch copy a file that takes longer than thirty seconds

`prefetchDatabaseHandler` in `packages/node-api/src/lib/prefetch-database.worker.ts` copies each file with `retry(async () => { ... })` and no timeout argument, so `retry`'s thirty second default applies. The metadata hash index of a real database is nine files of about 13 MB each, which a phone cannot pull down and write inside thirty seconds, so each times out, is retried, times out again, and eventually one exhausts its three attempts and takes the whole prefetch with it.

Pass `LARGE_FILE_TIMEOUT` from `packages/api/src/lib/constants.ts` to that retry, with the attempt count, base wait and scale spelled out as `sync.ts` and `replicate.ts` already spell them, and an error context naming the file. This is the same mistake in a third place, so the comment on it should say that rather than restating the mechanics.

Files:

- `packages/node-api/src/lib/prefetch-database.worker.ts`.
- `packages/node-api/src/test/lib/prefetch-database.worker.test.ts`: extend with the test listed under Unit Tests.

### 3. Run the prefetch as a background loop that keeps going until the replica is complete

Today `loadAssetsHandler` in `packages/node-api/src/lib/load-assets.worker.ts` queues a `prefetch-database` task at the end of its own run, and that is the only thing that ever queues one. A prefetch that fails is never tried again, and a replica whose prefetch failed is never repaired, because a sync cannot see a missing file (it copies what the merkle tree difference shows, and a partial replica already has the whole tree).

Add a third native background loop beside the import and sync loops, following the shape those two already have exactly. Do not invent a new pattern.

**The planning task.** Create `packages/mobile-worker/src/lib/plan-prefetch.worker.ts`, modelled line for line on `plan-sync.worker.ts`:

- Export `IPrefetchPassStep` and `IPrefetchPlanResult` with the same fields `IPlanSyncResult` has: `shouldRun`, `databasePath`, `reason`, `settings`, `pauseBetweenRunsMs`, `steps`.
- `planPrefetchHandler` reads `config.yaml` through `readConfigFromStorage`, refuses when `sync.enabled` is false, refuses when `computeSyncAllowed` refuses for the current connection type, resolves the database the same way `plan-sync` does (`sync.database_path`, falling back to `auto_import.default_database_path`), refuses when there is none, refuses when the database has no origin, and refuses when the database is not partial (use `isDatabasePartial` from `packages/node-api/src/lib/media-file-database.ts`).
- When it runs, `steps` holds one `prefetch-database` task carrying `{ databasePath }` and a job tag named "Filling in this database" with no cancel source, matching how `plan-sync` tags its sync task.
- `pauseBetweenRunsMs` comes from `sync.pause_between_runs_ms`, so no new configuration key is added.

Register `plan-prefetch` in `packages/mobile-worker/mobile-worker-entry.ts` beside `plan-sync`.

**Making a pass report whether there is anything left.** Change `prefetchDatabaseHandler` to return a result rather than `void`: an exported `IPrefetchDatabaseResult` with `filesFetched` and `filesStillMissing`. Every existing caller ignores the return value, so this is additive. `consolidate-database.worker.ts` calls the handler directly and must still compile.

**The driver.** Create `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/PrefetchPlan.java` mirroring `SyncPlan.java`, and `PrefetchDriver.java` mirroring `AutoImportDriver.java` rather than `SyncDriver.java`, because this loop does end itself:

- `PassOutcome` has `RAN` and `STOP`.
- A pass that is refused returns `RAN`, so the loop keeps asking, for the same reason the sync loop does: every refusal can go away without the app being touched.
- A pass whose `prefetch-database` step reports `filesFetched == 0 && filesStillMissing == 0` returns `STOP`: the replica is complete and there is nothing left to walk. Anything else returns `RAN`.
- A failed step returns `RAN`, which is what makes a failed prefetch retry.
- `Host.runStep` returns the step's `filesFetched` and `filesStillMissing` rather than a boolean, so add a small carrier type for that rather than overloading an int.

**Hosting it.** In `AutoImportService.java`, start a third thread for the prefetch loop beside the import and sync threads, under the same notification and the same wake lock, with a `PrefetchServiceHost` inner class mirroring `SyncServiceHost`. Its `pause` waits on the same `pauseLock`. `onDestroy` stops it with the other two. Restart the loop from `onStartCommand` when its thread is dead, the way the import loop is restarted, so that opening a database starts a stopped prefetch loop again.

In `JsEnginePlugin.java` add `readBackgroundPrefetchPlan()` and `runBackgroundPrefetchStep(PrefetchPlan.Step)` beside the sync pair.

**iOS.** Add `apps/ios-frontend/ios/App/App/JsEngine/PrefetchDriver.swift` mirroring `SyncDriver.swift`, register a `BGProcessingTask` for it in `AppDelegate.swift` beside the sync one, and add the matching entry points to `JsEnginePlugin.swift`. Add its unit tests to `apps/ios-frontend/ios/App/AppTests/` beside `SyncDriverTests.swift`. The iOS work must compile against Xcode 14.2 and macOS 12.7.6 and must not raise any minimum version.

**Leave `loadAssetsHandler` alone.** It should go on queueing a prefetch when a database is opened. That is the interactive path and it is what makes the first fill start immediately rather than at the top of the next gap.

Files:

- `packages/mobile-worker/src/lib/plan-prefetch.worker.ts` (new).
- `packages/mobile-worker/mobile-worker-entry.ts`.
- `packages/node-api/src/lib/prefetch-database.worker.ts`.
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/PrefetchPlan.java` (new).
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/PrefetchDriver.java` (new).
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/AutoImportService.java`.
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/JsEnginePlugin.java`.
- `apps/android-frontend/android/app/src/test/java/au/com/codecapers/photosphere/jsengine/PrefetchDriverTest.java` (new).
- `apps/ios-frontend/ios/App/App/JsEngine/PrefetchDriver.swift` (new), `JsEnginePlugin.swift`, `AppDelegate.swift`, `apps/ios-frontend/ios/App/AppTests/PrefetchDriverTests.swift` (new).
- `apps/smoke-tests/tests/57-prefetch-retries/test.sh` (new).

### 4. Hold the periodic sync back until the prefetch has finished filling the replica in

A sync that runs while the prefetch is still working does redundant work slowly and gets in its own way. Both were measured on the Pixel 6:

- Reaching the origin's merkle tree took **81.5 seconds** during a pass that overlapped the prefetch, against **97 milliseconds** when the phone was idle. They do not contend for engine slots and they contend hard for the network.
- The record merge in that pass took **15 minutes**, and the log shows why: it was pulling `.db/bson/collections/metadata/shards/*` down one at a time through the lazy storage, which is the same set of files the prefetch fetches. Letting the prefetch finish first means the merge reads a local database instead.

So while a prefetch is outstanding for a database, the periodic sync of that database should not run.

**The hazard this must not create.** If the sync waits for a prefetch that can never finish, syncing never happens again, which is worse than the contention. The measured prefetch did exactly that: it failed and was never retried. Steps 2 and 3 make it able to finish and to retry, but the deferral must not depend on that being true, so it is bounded by progress rather than by completion.

**The rule.** The sync defers only while the prefetch is *making progress*. Concretely, from the prefetch driver's most recent pass:

- Nothing fetched and nothing missing: the replica is complete, the prefetch loop has stopped, sync runs.
- Something fetched and files still missing: the prefetch is working, sync defers.
- Nothing fetched and files still missing: the prefetch is stuck, sync stops waiting and runs.
- No pass has completed yet: sync runs, because nothing is known and refusing on no evidence is how a loop gets stuck.

**Where the decision lives.** In TypeScript, not in the driver. The native side reports a fact and `plan-sync` decides what it means, exactly as it already does for the connection type: `readNetworkConnectionType` reports `wifi` or `cellular` and `computeSyncAllowed` decides. Follow that:

- `PrefetchDriver` (both platforms) keeps its most recent pass result and exposes it as a small state value: `complete`, `working`, `stalled` or `unknown`.
- `AutoImportService.SyncServiceHost.readPlan` passes that value into `JsEnginePlugin.readBackgroundSyncPlan`, which passes it to the `plan-sync` task as input data. The same on iOS.
- `planSyncHandler` in `packages/mobile-worker/src/lib/plan-sync.worker.ts` changes its first parameter from `_data: object` to a named `IPlanSyncData` interface carrying `prefetchState`, and refuses with a reason naming the wait when it is `working`. Put that check after the master switch and the connection check and before the database resolution, so the reason a user is most likely to care about still wins.

**What is not deferred.** Only the periodic background sync. A sync the user asks for, and the one an edit in the app triggers, do not go through `plan-sync` and must be left alone: a user who presses sync means now.

**Automatic import is not deferred either.** It writes locally and the plan does not touch it. Whether an import should also wait for a prefetch is a real question and is deliberately not answered here.

Files:

- `packages/mobile-worker/src/lib/plan-sync.worker.ts`.
- `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts`.
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/PrefetchDriver.java`, `AutoImportService.java`, `JsEnginePlugin.java`.
- `apps/android-frontend/android/app/src/test/java/au/com/codecapers/photosphere/jsengine/PrefetchDriverTest.java`.
- `apps/ios-frontend/ios/App/App/JsEngine/PrefetchDriver.swift`, `JsEnginePlugin.swift`, and `apps/ios-frontend/ios/App/AppTests/PrefetchDriverTests.swift`.
- `apps/smoke-tests/tests/58-sync-waits-for-prefetch/test.sh` (new).

### 5. Write the documentation

Update, naming what each has to say:

- `docs/syncing.md`: the section on what a sync does and does not move currently ends by saying reopening the database is the only thing that fills a replica in. Correct that to the background prefetch loop, say which settings it obeys (the two `sync` settings and the same gap), and say that a failed pass is retried on the next one. Add the loop to the "While the app is not on screen" table and to the "What each platform can do" table. Add the ordering from step 4 to "When a sync is refused": a periodic sync waits while a prefetch of the same database is making progress, it stops waiting if that prefetch stalls, and a sync the user asks for is never deferred. Give the reason with the measured numbers, because "it is faster afterwards" is not obviously true until someone sees 81.5 seconds against 97 milliseconds.
- `docs/automatic-photo-backup.md`: the subsection "And then the push to the origin fails, silently, every time" describes behaviour this plan removes. Replace it with what an upload from an encrypted database now does, and keep the measured cost of the batch write, which this plan does not change.
- `docs/mobile-background-tasks.md`: there are now three background loops sharing the engine pool and one foreground service, not two. Update the count and the description, and say what the third one does.
- `docs/performance/mobile-sync-at-scale.md`: add a short closing section saying which of its findings have since been fixed and which stand. The 86 second first open, the ten minute load, the sixteen minute batch write and the memory pressure all still stand and must not be presented as fixed.
- The wiki's configuration file page is outside this repository and gains no new key, since the prefetch loop reuses the `sync` section. Note that no wiki change is needed.

### Commit and prove, at the end of every step

1. `bun run compile`.
2. `bun run test` and `bash apps/android-frontend/scripts/android-gradle.sh :app:testDebugUnitTest`.
3. `bun run tev`. If the change gate skips a suite that this step's files affect, run that suite by name.
4. The mobile suite on the emulator pool: check `bun run emu:and:pool:status` at the moment it is needed, then `bun run test:and`.
5. The mobile suite on the real device: read the serial from `adb devices -l` by picking the entry whose `model` is not an emulator, and run `PHOTOSPHERE_ANDROID_DEVICES="<that serial>" bun run test:and`. Never hard code a serial into any file.
6. A failure is not permitted to be waved through as flaky. Re-run the failing suite alone; if it passes, run it again to establish whether it is load dependent, and say plainly in the commit message or to the human what was seen. Do not proceed on an unexplained red.
7. `/me:commit:detz` to produce the message, then `/me:commit:do` to stage and commit. The pre-commit hook runs the test set and must not be bypassed: `--no-verify` is banned. Start the commit as a background command, because the hook outlives a foreground one.
8. Push the worktree branch only, with `git push -u origin HEAD` on the first push and `git push` after. Never push `main`.
9. Watch the Release workflow for that push to completion: `gh run list --branch <branch> --limit 1` for the run id, then `gh run watch <id>`. It must be green on every job, including `android-smoke-tests`, `ios-smoke-tests`, `build-linux`, `build-windows` and `build-desktop`. Do not start the next step until it is.
10. If the workflow is red, fix the cause and commit the fix as its own commit, repeating this procedure, before moving on.

## Unit Tests

- `packages/mobile-worker/src/test/shims/node-stream.test.ts`: the shim `Transform` yields every pushed buffer in order through `for await ... of`; an iterator started before any write still receives everything; an iterator started after writes have been buffered receives the buffered bytes and not only what follows; the iterator completes when `end()` is called; the iterator rejects when the transform is destroyed with an error; the iterator yields nothing and completes for a transform ended with no data.
- `packages/mobile-worker/src/test/shims/node-stream.test.ts`: a shim `Transform` piped through the same shape `createEncryptionStream` produces is consumable by an async iterator, which is the arrangement the AWS uploader puts it in.
- `packages/node-api/src/test/lib/prefetch-database.worker.test.ts`: a file whose read takes longer than thirty seconds is still copied, using fake timers the way `copies a file that takes longer than the default retry timeout to read` in `packages/node-api/src/test/lib/replicate.test.ts` does, and watched failing before step 2's change.
- `packages/node-api/src/test/lib/prefetch-database.worker.test.ts`: the handler returns `filesFetched` and `filesStillMissing`; both are zero for a replica with nothing missing; `filesStillMissing` is non zero when the run is cancelled part way.
- `packages/mobile-worker/src/test/lib/plan-prefetch.worker.test.ts` (new): every refusal has its own test (syncing off, connection not allowed, no database, no origin, database not partial) and each asserts the reason and that `steps` is empty; the running case asserts the database path, the single `prefetch-database` step, its job tag and the pause taken from `sync.pause_between_runs_ms`.
- `apps/android-frontend/.../PrefetchDriverTest.java` (new): a refused plan keeps the loop going; a pass reporting nothing fetched and nothing missing ends the loop; a pass reporting files still missing keeps it going; a failed step keeps it going; a second pass cannot start while one is in flight; a stopped driver runs no further passes.
- `apps/ios-frontend/ios/App/AppTests/PrefetchDriverTests.swift` (new): the same decisions as the Android driver test.
- `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts`: a prefetch state of `working` refuses the pass and names the wait in the reason; `stalled` allows it, which is the test that proves a stuck prefetch cannot stop syncing for ever; `complete` allows it; `unknown` allows it; the master switch and the connection check still win over the prefetch state, so a pass refused for both reports the switch rather than the wait.
- `apps/android-frontend/.../PrefetchDriverTest.java` and `apps/ios-frontend/.../PrefetchDriverTests.swift`: the driver reports `unknown` before any pass has completed, `working` after a pass that fetched files and left some missing, `stalled` after a pass that fetched nothing and left some missing, and `complete` after a pass that fetched nothing with nothing missing.

React components, contexts and hooks are not unit tested and none are touched by this plan.

## Smoke Tests

- `apps/smoke-tests/tests/56-large-asset-push/test.sh` (new). An encrypted S3 database on the emulator, as `45-s3-share-replica-sync` sets one up, holding an asset big enough that the upload cannot be a trivial one. Import it on the device, let a sync push it, and assert the object is in the bucket with the right length by reading the bucket from the host rather than by believing anything the app says. This is the test that would have caught the multipart failure, and it must be watched failing before step 1's change. The fixture must be generated by the test rather than committed: a few megabytes of incompressible bytes written into the device's photo library, so the repository does not grow a binary. Give it a `PHOTOSPHERE_PER_TEST_TIMEOUT` allowance if the default is too short for the upload.
- `apps/smoke-tests/tests/57-prefetch-retries/test.sh` (new). A partial replica on the device whose origin holds thumbnails it lacks, with syncing switched on so the loop runs. Assert the missing files appear in the replica's storage on the device without the database being opened again, which is what proves the background loop rather than the `load-assets` queue did it. Then assert a second pass after everything is present does not keep running, by checking the loop stops.
- `apps/smoke-tests/tests/58-sync-waits-for-prefetch/test.sh` (new). A partial replica with files missing at the origin, syncing switched on, and an edit made locally so that a sync would have something to push. Assert that no sync pass runs while the prefetch is still fetching, and that one runs once the prefetch has finished. Read the outcome from the origin bucket and the app log rather than from a spinner. Include the stalled case: with the origin made unreachable for the prefetch's files but reachable for the sync, assert syncing is not blocked for ever.
- All must pass on the emulator pool and on the real device.

## Verify

- `bun run compile` passes.
- `bun run test` passes, every package.
- `bash apps/android-frontend/scripts/android-gradle.sh :app:testDebugUnitTest` passes.
- `bun run tev` passes.
- `bun run test:and` passes on the emulator pool.
- `PHOTOSPHERE_ANDROID_DEVICES="<real device serial>" bun run test:and` passes on the Pixel.
- The Release workflow is green on every job for the final commit on the branch.
- A phone with an encrypted S3 origin, given a photo, has that photo's original in the bucket afterwards. `56-large-asset-push` is the automated form of this and is the one that matters.
- `grep -rn "not a function" ` over a device capture during `56-large-asset-push` finds nothing from the upload path.

## Notes

- **Why there is no user facing error for a failed push.** `syncDatabases` already leaves a file that will not copy for the next pass to retry, which is retry until it works. The problem measured was not that the retry was missing, it was that the copy could never succeed. Once step 1 lands, the existing behaviour is correct and an error message the user cannot act on would be noise.
- **The one thing that behaviour does not cover** is a file that can never upload for a reason that will not go away, which would be retried every pass for ever, spending battery and data. Nothing in this plan addresses that, and nothing measured has produced such a file. If it becomes real, a backoff on a file that has failed the same way several passes running is the shape to reach for, not an error message.
- **Why the prefetch loop obeys the sync settings** rather than getting its own. It is network traffic to the origin on the user's connection, and a user who switches syncing off means stop using my data for this database. Reusing the two settings and the gap also means no new configuration key, no wiki change, and one rule to keep in step instead of two. The `load-assets` queued prefetch is deliberately not made to obey them, because that one is the user opening the database in front of them.
- **The ordering in step 4 is the one part of this plan that can make things worse if it is got wrong.** A sync that waits for a prefetch that never finishes is a phone that has stopped backing up, silently, which is the exact failure this whole plan exists to remove. That is why the deferral is bounded by progress rather than by completion, why `unknown` allows syncing rather than refusing it, and why the stalled case has both a unit test and a smoke test of its own. If any of that is dropped during implementation, drop the ordering with it.
- **Why the loop stops and the sync loop does not.** A sync has reasons to refuse that go away on their own, so it asks for ever. A prefetch that has fetched everything has nothing left to do, and asking again means walking every object at the origin every gap, which on this database is 8,231 listings and 8,231 local existence checks. Stopping and being restarted when a database is opened is cheaper and is the pattern `AutoImportDriver` already uses.
- **`EnginePool.POOL_SIZE` is 5** and a third loop adds at most one more concurrent task, so the pool is not at risk. Measured occupancy during the work behind this plan never exceeded three.
- **What this plan does not fix, deliberately.** The sixteen minute batch write into a large database, the 86 second first open and the ten and a half minute load, and the 83 MB allocation that was refused during a sync. Those are separate work and `docs/performance/mobile-sync-at-scale.md` keeps the numbers.
- **The push order reaches originals before thumbnails**, which is why the measured run never got as far as a thumbnail. That is not addressed here; it only matters while originals fail.
