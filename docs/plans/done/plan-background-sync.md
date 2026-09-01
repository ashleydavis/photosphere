# Sync to the remote while the app is not on screen

## Overview

Automatic import runs on the native side of both mobile apps and keeps working when the app is backgrounded or the screen is off. Sync does not. `MobileSyncScheduler` in `packages/mobile-frontend/src/lib/mobile-sync-scheduler.ts` lives in the WebView, driven by `platform-provider-mobile.tsx`, on a debounce timer and a five minute interval. The operating system throttles and then stops a WebView's timers once the app is backgrounded, which is the same reason the import loop was moved off them.

So a phone that imports photos in the background writes them to the local database and pushes nothing. They reach the remote only when someone opens the app. For a photo backup app that is the half that matters: the photos are on the phone either way, and the point of the feature is that they are somewhere else too.

This does for sync what was already done for import: a planning task in TypeScript that decides whether a sync should run, a native driver that runs the loop, and the existing Android foreground service hosting it. The WebView scheduler goes, so there is one sync loop rather than two racing.

Android is tested on real hardware as part of this work. A Pixel 6 is attached to this machine and MinIO runs on it, so the whole loop can be exercised for real: a photo landing on a phone that is not on screen, reaching an S3 remote. `apps/smoke-tests/tests/45-s3-share-replica-sync` already does the MinIO half against a device and is the starting point rather than something to build again.

iOS is written to the same design and verified through GitHub Actions. There is no macOS on this machine, but `.github/workflows/release.yml` has `ios-unit-tests` and `ios-smoke-tests`, both on `macos-14`, so the iOS half is checked by pushing and reading the run. That is a real verification and the plan is not finished until it is green. Nothing is committed until the human asks; they push, and the workflow is then this work's to get passing, every job in it and not only the iOS ones.

## Issues

## Steps

1. **Write the documentation first.** Create `docs/syncing.md`, doing for sync what `docs/automatic-photo-backup.md` does for import: what it is, how it decides there is anything to push, what a pass costs, what each platform can and cannot do, where the settings live, and how it behaves while the app is not on screen. Use that file as the model for structure and for tone, and finish it with a Tests section listing what covers it, the same way that one does. It has to stand on its own: someone reading only `docs/syncing.md` should understand syncing without reading the import doc first.

   Then update `docs/automatic-photo-backup.md` to point at it and to stop being wrong: the note at line 11 saying nothing is pushed until the app is opened comes out once that is no longer true, and the "While the app is not on screen" section says sync now runs there too rather than describing import alone.

   STOP when both are drafted and wait for the human to approve them. If they revise either, revise the steps below to match before writing any code.

2. **Move the two sync settings somewhere the native side can read.** `Enable syncing` and `Only sync over Wi-Fi` are stored in the WebView's config store under the keys `syncEnabled` and `syncOnlyOnWifi` (`packages/user-interface/src/context/sync-context.tsx`). Nothing outside the WebView can read that, which is the same wall the import settings hit. Persist both to a file in the app's storage sandbox that the worker can read, following what `auto-import.toml` does and reusing `packages/api/src/lib/mobile-config-paths.ts`. The toggles in `configuration-dialog.tsx` keep working and keep their `data-id`s (`sync-enabled-toggle`, `sync-wifi-only-toggle`) so the smoke tests can drive them. The code must compile and all unit tests pass.

3. **Give the worker the network state.** `computeSyncAllowed` in `packages/user-interface/src/lib/sync-gate.ts` already refuses when syncing is off, when offline, when the connection type is `none`, and when Wi-Fi-only is on and the connection is cellular. It is fed by the WebView's network status, which a background service does not have. Add a host function that reports the current connection type from native, on both platforms, following how the other host functions are declared and installed. Android reads it through `ConnectivityManager` and its transport capabilities; iOS through `NWPathMonitor`. It must be able to say `wifi`, `cellular`, `none` and `unknown`, because `computeSyncAllowed` treats `unknown` as permitted and treats `cellular` as the one to refuse.

4. **Add a `plan-sync` worker task.** Create `packages/mobile-worker/src/lib/plan-sync.worker.ts` following `plan-auto-import.worker.ts`, and register it in the mobile worker's task registration beside `plan-auto-import`. It answers one question: should a sync run right now, and against which database. It reads the settings file from step 2, asks the host function from step 3 for the connection type, and calls the existing `computeSyncAllowed` rather than writing the rule again: a second copy of that rule is a second thing to keep in step, and the Wi-Fi restriction going wrong means somebody's mobile data bill. It also checks the database has an origin configured, since a database with no remote has nothing to sync to. It returns `shouldRun`, `databasePath`, the `sync-database` step to queue, and the pause before the next attempt. Native code must never assemble a task payload of its own, exactly as with import.

   `computeSyncAllowed` lives in `packages/user-interface`, which the worker should not depend on. Move it and `ISyncGateInputs` to `packages/api` with its tests, and re-export from where the user interface imports it now so nothing there changes. That keeps one implementation of the rule for both callers.

5. **Add the Android driver.** Create `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/SyncDriver.java` and `SyncPlan.java`, mirroring `AutoImportDriver.java` and `AutoImportPlan.java`: a `Host` interface for everything that touches the platform, a `runLoop` that reads a plan, runs its step, pauses and repeats, `stop`, and no Android imports in the driver itself so its decisions are testable on the JVM. A pass that fails must not end the loop, for the same reason import's does not.

6. **Host the sync loop in the existing foreground service.** Change `AutoImportService.java` to run the sync driver as well as the import driver, on its own thread, under the one notification and the one wake lock. Do not add a second service: two foreground services means two notifications for one feature. The service must start and stop both loops together, and `JsEnginePlugin.startAutoImportService` / the stop path must need no change beyond what falls out of that.

7. **Serialise a sync against an import.** A sync must not run while an import pass is mid-flight, because the import holds the database write lock and the sync would queue behind it holding an engine slot. Decide where this is enforced (the plan task refusing, or the service ordering the two loops) and implement it there. Whichever is chosen, the reason goes in a comment: `EnginePool.POOL_SIZE` bounds how many tasks can be in flight, and `import-assets` plus its children already use most of it.

8. **Remove the WebView scheduler.** Delete `packages/mobile-frontend/src/lib/mobile-sync-scheduler.ts` and its test, and take out the calls in `platform-provider-mobile.tsx` that drive it (`notifyDatabaseEdited`, `setSyncAllowed`, the database-opened hook and the sync-started/sync-completed handling that feeds it). Leave the platform-context methods themselves if the shared user-interface package calls them; make them no-ops with a comment saying the native loop now owns syncing, rather than removing methods the shared package expects. The code must compile and all unit tests pass.

9. **Add the iOS driver.** Create `apps/ios-frontend/ios/App/App/JsEngine/SyncDriver.swift` mirroring `AutoImportDriver.swift`: the same host protocol, the same loop, the same single-pass serialisation. Register a `BGProcessingTask` for sync in `AppDelegate.swift` beside the import one, and ask for one after each pass. Add the iOS side of the connection-type host function from step 3 using `NWPathMonitor`, and XCTests for the driver and for that function under `apps/ios-frontend/ios/App/AppTests/`, matching the Android JVM tests one for one.

    None of this can be compiled or run on this machine. Do not claim any of it works. It is verified in step 13 by the workflow, and until that run is green the honest description is that it is written and unchecked.

10. **Add an Android smoke test, built on the one that already does most of this.** `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh` already stands up a MinIO bucket with `start_s3_emulator` from `apps/smoke-tests/lib/`, points the app at it, and syncs a real Android target against it. Read it before writing anything: it is the template, and the MinIO plumbing is done.

    Create `apps/smoke-tests/tests/50-background-sync/test.sh` combining that with `49-background-import/test.sh`: start MinIO the same way, connect the app's database to the bucket as its origin, then put a photo into the device library while the app is backgrounded and assert it reaches the bucket without the app ever being opened. Measure by reading the bucket rather than by anything the app says, for the same reason test 49 measures on disk: a backgrounded WebView may have its socket to the harness suspended, which is the exact moment this test cares about. Add an `IOS-NOT-COVERED.md` beside it matching test 49's.

11. **Run it on the physical device.** A Pixel 6 is attached to this machine and MinIO runs on this machine, so the whole loop is testable here: real phone, real background service, real S3 remote. Run the new test against it, and against the emulator pool as well if it works there, since the pool is what the suite normally uses.

    Two things the run needs. The mobile harness refuses to wipe a real phone unless `PHOTOSPHERE_ALLOW_DEVICE_WIPE=1` is set, so ask the human before running anything that clears the phone: an imported library on it represents about forty minutes of work. And the phone reaches MinIO over the LAN rather than over `localhost`, so the app has to be pointed at this machine's LAN address; check how test 45 resolves the host address for a device target rather than assuming `10.0.2.2` or `127.0.0.1`, since those are emulator answers.

12. **Update the documentation.** Revise `docs/syncing.md` and the cross-reference in `docs/automatic-photo-backup.md` so both match what was built, including what iOS does and does not do. Fill in the Tests section of `docs/syncing.md` with what actually ended up covering it.

13. **Get the workflow green, iOS included.** Nothing is committed until the human asks for it. When they do, and once they have pushed, watch the run of `.github/workflows/release.yml` with `gh run watch` / `gh run view --log-failed` and take every failure in it as this work's to fix, not only the iOS ones. The jobs that cover what this plan changes:

    | Job | Runner | What it checks here |
    |---|---|---|
    | `ios-unit-tests` | `macos-14` | The new XCTests for `SyncDriver.swift` and the connection-type function, and that the iOS project still builds at all. |
    | `ios-smoke-tests` | `macos-14` | The app running on the simulator with the sync driver in it. |
    | `android-unit-tests` | ubuntu | The JVM tests for `SyncDriver.java`. |
    | `android-smoke-tests` | ubuntu | The mobile suite including the new `50-background-sync`, if it can run there. |
    | `sync-tests` | ubuntu | `test:cli:sync`, several processes syncing one database, which the settings move could break. |
    | `unit-tests`, `compile` | ubuntu | The settings move and `computeSyncAllowed` changing packages. |

    Expect iOS to fail first and more than once: it is the half written blind. Read the actual failure from the log rather than guessing at it, fix, and ask the human to push again. The plan is finished when the whole workflow is green, and until then say which jobs have passed rather than describing the work as done.

## Unit Tests

### What already covers syncing, and must keep passing

Read these before writing anything: they say what syncing is already required to do, and a change that breaks one of them has changed behaviour rather than added to it.

| Existing test | What it holds |
|---|---|
| `packages/node-api/src/test/lib/sync-database.worker.test.ts` | The `sync-database` task itself: the thing both the old WebView scheduler and the new driver queue. |
| `packages/node-api/src/test/lib/sync-early-out.test.ts` | Sync doing nothing when there is nothing to do. A background loop makes this matter far more, because it will now run against an unchanged database over and over. |
| `packages/node-api/src/test/lib/sync-metadata-edit.test.ts` | An edit reaching the origin. |
| `packages/user-interface/src/test/lib/sync-gate.test.ts` | The gate that decides syncing is permitted at all. Whatever replaces the WebView scheduler still has to respect it. |
| `packages/mobile-frontend/src/test/mobile-sync-scheduler.test.ts` | The WebView scheduler being deleted in step 6. This test goes with it. |

### New

- `planSyncHandler` in `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts`, one test per way it can refuse and one for the way it can agree:
  - **`Enable syncing` off means no sync.** `shouldRun` is false and no step is returned, whatever else is true. This is the setting a user reaches for when they want it to stop, so it has to be the first thing checked and the hardest to get past.
  - **`Only sync over Wi-Fi` on and the connection is cellular means no sync.** `shouldRun` is false. Getting this wrong spends somebody's mobile data without asking.
  - **`Only sync over Wi-Fi` on and the connection is Wi-Fi means a sync runs.** Otherwise the restriction would read as "never sync".
  - **`Only sync over Wi-Fi` on and the connection type is unknown means a sync runs**, matching what `computeSyncAllowed` already does, so the desktop and anything that cannot report a type is not silently stopped.
  - **`Only sync over Wi-Fi` off and the connection is cellular means a sync runs.**
  - Offline, or a connection type of `none`, means no sync.
  - No default database recorded, or a database with no origin, means no sync.
  - When it should run: the `sync-database` step comes back with the right database path, and the pause is carried through.
- The settings reader added in step 2: an absent file reads as syncing off rather than on, and a file that cannot be parsed does the same. A settings file nobody can read must never be the reason a phone starts pushing over cellular.
- The connection-type host function's TypeScript side: each value it can return maps to the `NetworkConnectionType` `computeSyncAllowed` expects, and anything unrecognised maps to `unknown` rather than throwing.
- `computeSyncAllowed`'s existing tests move with it to `packages/api` in step 4 and must keep passing unchanged. If any of them has to be edited, the rule has changed and that is a decision, not a refactor.
- `SyncDriver` on the JVM in `apps/android-frontend/android/app/src/test/java/.../SyncDriverTest.java`, following the existing `AutoImportDriver` test: a plan saying stop ends the loop, a failing pass does not end the loop, `stop` ends it, and the pass is not run again while one is in flight.
- Whatever function step 5 adds to keep a sync and an import apart gets a unit test that fails when the two are allowed to overlap.
- Whatever replaces the deleted scheduler's respect for the sync gate gets a test, so that behaviour is not lost with the file.

## Smoke Tests

### What already covers syncing end to end, and must keep passing

None of these covers a sync that happens with the app off screen, which is the gap this plan fills. Every one of them covers something the change could break.

| Existing test | What it proves | Why it matters here |
|---|---|---|
| `apps/smoke-tests/tests/45-s3-share-replica-sync` (mobile, Android) | An edit made on the phone reaches an encrypted S3 origin, and the sync early-out fires when there is nothing to sync. | The closest thing to this feature that exists, and **the template for the new test**: it already stands up MinIO with `start_s3_emulator`, points the app at the bucket and syncs a real Android target against it. It also proves foreground syncing still works once the WebView scheduler is gone. |
| `bun run test:cli:sync` (`apps/cli/sync-smoke-test.sh`) | Several processes syncing one database at once. | The background loop adds another writer. If sync and import can overlap, this is the suite that shows what that costs. |
| `84-watch-sync-evict` (CLI) | Imports reach the origin once `psi sync` pushes them, and local originals stay. | The same end-to-end path this plan automates on mobile. |
| `85-consolidate`, `86-multi-device` (CLI) | Sync between related databases, and two devices on one remote. | Sync's preconditions. The plan task must not start a sync where these say one should be refused. |
| `36-consolidate-database` (Electron) | Consolidating through the UI leaves ordinary sync working. | The desktop path, unchanged by this plan and therefore a regression check. |
| `49-background-import` (mobile, Android) | Import keeps running while the app is backgrounded and while the screen is off, and the foreground service is running throughout. | Must keep passing unchanged: it is what proves the import loop was not broken by sharing the service. |

### New

- `apps/smoke-tests/tests/50-background-sync/test.sh` as described in step 8: a photo imported while the app is backgrounded reaches the origin with the app never opened, asserted by reading the origin rather than by anything the app says.
- The same test asserts the negative that matters: with automatic import switched off nothing is pushed, so a pass is not just the app syncing when it is next launched.
- **The two settings are driven through the real UI and their effect asserted on the origin**, because they are what a user reaches for and neither is covered end to end today:
  - With **`Enable syncing`** switched off at `sync-enabled-toggle`, a photo imported in the background reaches the local database and **nothing reaches the origin**. Switch it back on and the same photo then arrives. Asserted by reading the origin, so it is the push being tested and not a label in the app.
  - With **`Only sync over Wi-Fi`** switched on at `sync-wifi-only-toggle` and the emulator's connection forced to cellular, **nothing reaches the origin**. Restore Wi-Fi and it arrives. On an emulator the connection type is settable from the host, so this is drivable without a SIM; if it turns out not to be on the pool image, say so in the test rather than dropping the case, and cover the decision in the plan task's unit tests alone.
  - Both cases assert the app is still running and the service is still up while nothing is being pushed, so a refusal to sync is distinguishable from a crash. A test that passes because the app died is worse than no test.
- The same test asserts a sync happens with the screen off, not only with the app backgrounded, since those are different states and `49-background-import` covers both for import.
- An `IOS-NOT-COVERED.md` beside it, matching `49-background-import`'s, saying what iOS cannot cover and why.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test:everything -- --force` passes.
- `mise exec -- bun run test:and:unit` passes, covering the new JVM tests.
- The new smoke test passes on Android.
- A photo taken while the app is backgrounded reaches the origin without the app being opened, observed on a real device.
- With `Enable syncing` switched off, a background import puts the photo in the local database and nothing reaches the origin. Observed on a device, by reading the origin.
- With `Only sync over Wi-Fi` switched on and the connection cellular, nothing reaches the origin; on Wi-Fi the same photo does. Observed the same way.
- Every job in `.github/workflows/release.yml` passes on the pushed branch, including `ios-unit-tests` and `ios-smoke-tests`. Until that run is green the iOS half is written and unchecked, and must be described that way.

## What to read before starting

Automatic import already does all of this, and the fastest way into the problem is to read how, rather than to work it out again.

- **`docs/automatic-photo-backup.md`**, sections "Passes, not watching" and "While the app is not on screen". This is the design being copied and the reasoning behind it, including why the WebView was abandoned and what each platform can honestly promise.
- **`docs/mobile-background-tasks.md`** in full. It is short and it is the constraint this plan is most likely to break. "Why running out is a hang, not a slowdown" and "Rules for adding a background task to mobile" are the two that matter here.
- The reference implementation, in this order: `packages/mobile-worker/src/lib/plan-auto-import.worker.ts`, then `apps/android-frontend/.../jsengine/AutoImportDriver.java` and `AutoImportPlan.java`, then `AutoImportService.java`, then `apps/ios-frontend/.../JsEngine/AutoImportDriver.swift`. Each new file in this plan is the same file with sync in place of import.

### How the import loop is put together

The native side holds no decisions. It calls the `plan-auto-import` task, gets back `IPlanAutoImportResult` (`shouldRun`, `databasePath`, `settings`, `pauseBetweenRunsMs`, and `steps`, each step a task type and its already-built payload), runs each step through the engine pool, pauses, and repeats. Native code never builds a payload of its own, so what a pass does is decided once in TypeScript and cannot drift between Android and iOS. Copy that division exactly.

The driver takes everything platform-shaped through a `Host` interface (Java) or `AutoImportDriverHost` protocol (Swift): read a plan, run a step, pause, report, report an error. That is what lets the loop's decisions be unit tested on the JVM with no device, and it is why `SyncDriver` must have no Android imports in it.

A pass that fails does not end the loop. An import can fail for a reason that has since gone, and giving up would leave the feature switched on in the interface and doing nothing. Sync has more of those reasons than import does, not fewer: no network, a remote that is briefly unreachable, an expired credential.

Two passes at once is made unreachable rather than unlikely: there is one driver for the life of the app with one entry point, and asked to run while a pass is in flight it waits for that pass and returns its outcome rather than starting a second. On iOS both the foreground loop and the system's background task call it and neither knows about the other, which is exactly why it is written that way.

### The facts that were learned the hard way

- **The engine pool is five slots** (`EnginePool.POOL_SIZE` in `EnginePool.java`, kept in step with `EnginePool.swift`). `import-assets` holds one for the whole run and its `hash-file` and `upload-asset` children hold more. Adding a second long-running loop is the exact shape that once deadlocked the pool: a separate `auto-import` task sat in a slot for as long as the setting was on and started an `import-assets` in a second slot, and the whole thing stopped, silently, with the setting on, the task showing as running and the counts at zero forever. That is why this plan has a step for keeping sync and import apart, and why that step is not optional.
- **A deadlocked loop looks identical to a working one from outside.** The test that caught it waits for the photo to arrive, not for the task to start. Write the sync test the same way: wait for the asset to appear at the origin, never for a task to be queued.
- **A backgrounded WebView may have its socket to the harness suspended**, which is the exact moment the test cares about. Test 49 measures by counting originals on disk through `run-as` rather than by anything the app reports. The new test must read the origin directly for the same reason.
- **The wake lock is held only while a pass is running**, and released in between. A foreground service keeps the process alive but does not keep the CPU awake once the screen is off, and a lock held all night flattens the phone. Sync passes are shorter than import passes but the rule is the same.
- **The settings live in `auto-import.toml`** in the app's storage sandbox, not in WebView `localStorage`, precisely because a service that wakes up has to read them and nothing outside the WebView can read `localStorage`. Anything the sync loop needs to know has to be somewhere the native side can reach.
- **Importing and syncing are deliberately two separate operations.** `psi add --watch` knows nothing about the origin and `psi sync --watch` pushes what is there. Do not merge them: the point of this plan is that both loops run in the background, not that one becomes the other.

## Notes

- **iOS is written blind here and verified in CI.** There is no macOS on this machine, so nothing about the iOS half can be claimed as working from here; `ios-unit-tests` and `ios-smoke-tests` on `macos-14` are what check it, and the work is not done until they pass. Expect more than one round. Separately, what iOS can promise is weaker in kind: a `BGProcessingTask` runs when the system decides, so sync catches up rather than running continuously, and the documentation has to say that.
- **The engine pool is the real constraint.** `import-assets` holds a slot for the length of a run and its `hash-file` and `upload-asset` children hold more, all inside `EnginePool.POOL_SIZE`. Adding a second long-running loop is exactly the shape that once deadlocked the pool silently, with the setting on and the counts at zero forever. That is why step 5 exists and why it is not optional. See `docs/mobile-background-tasks.md` before changing anything about the pool.
- **One service, not two.** Android requires a foreground service to post an ongoing notification. A second service means a second notification for one feature, which is a visible product change nobody asked for.
- **Open question for step 5:** whether the plan task refuses a sync while an import is running, or the service simply runs the two loops in sequence. Sequencing in the service is simpler and keeps the decision out of TypeScript; refusing in the plan task keeps every decision in one language, which is the reason the import plan task exists at all. Worth deciding deliberately rather than by whichever is written first.
- **The WebView scheduler and the native loop must not both run.** Step 6 is not tidying-up that can be deferred: two schedulers would queue two syncs, and the second would sit behind the first holding an engine slot.
