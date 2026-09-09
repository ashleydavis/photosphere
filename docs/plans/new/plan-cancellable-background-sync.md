# Let the user cancel a background sync from the jobs list

## Overview

The jobs list shows "Syncing database" running and offers no way to stop it. That is deliberate today and written down twice: `enqueueSyncTask` in `apps/desktop/src/main.ts` and the plan builder in `packages/mobile-worker/src/lib/plan-sync.worker.ts` both leave `cancelSource` out of the job tag, so the row renders without a Cancel button, and `docs/background-tasks.md` gives the reasoning ("syncing is switched off from Settings"). That reasoning does not survive contact with a phone: a sync of a real library moves gigabytes over somebody's connection, and switching syncing off in Settings to stop it is a different act with a different meaning, because it also stops every future pass. The user wants the ordinary thing: stop this one, and let the next interval start a fresh one. Two pieces are missing for that. The job tag has to carry a `cancelSource` the interface can name, and the sync itself has to notice: `sync.ts` and `sync-database.worker.ts` do not mention cancellation at all, so cancelling today would drop a queued sync and do nothing at all to one already running.

## Issues

## Steps

1. **Make a running sync stoppable.** Thread cancellation through the sync itself, which is where the real work is: `syncDatabaseHandler` in `packages/node-api/src/lib/sync-database.worker.ts` has `context.isCancelled()` available and never calls it, and `syncDatabases` in `packages/node-api/src/lib/sync.ts` takes no cancellation argument. Add an optional `isCancelled` callback to the sync's options, pass `() => context.isCancelled()` from the handler, and check it at the points where stopping is safe and useful: before each phase (pull, merge, push, stamp) and between files inside the file-moving loops, which is where a large sync spends its time. Do not check it inside a write-lock acquisition or between a lock and its `finally`. The existing `try`/`finally` blocks release both write locks, so a cancellation that throws leaves no lock held; verify that by reading the code rather than assuming it. Unit tests for both changed functions. `bun run compile` and `bun run test` must pass before this step is finished.

2. **Report a cancelled sync as cancelled, not as a failure.** Decide and implement one outcome for it in `sync-database.worker.ts`: a cancelled pass must not be logged as an error, must not leave the state files stamped as though the two sides had been made equal, and must leave both databases valid, which they are by construction because a half-finished sync is a normal state the next pass works out for itself. Add the outcome to the task's result and unit test it. Compile and tests pass.

3. **Give the desktop's sync job a cancel source.** In `enqueueSyncTask` in `apps/desktop/src/main.ts`, add `cancelSource: currentDatabasePath` to the job tag: the task is already queued with `currentDatabasePath` as its source, so the name the interface needs already exists and nothing else has to change to route the cancel. Then check what resets `isSyncRunning`: it is set true when the task is queued and cleared from the completion path, so if a cancelled task does not reach that path the desktop queues no further syncs for the life of the process. Make the reset cover cancellation, and note in the code why. Compile passes; the behaviour is covered by the desktop smoke test below.

4. **Give the mobile sync job a cancel source.** In `packages/mobile-worker/src/lib/plan-sync.worker.ts`, add `cancelSource` to the job tag. The value is the source the native driver queues under, which is the fixed string in `BACKGROUND_SYNC_TASK_SOURCE` in `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/JsEnginePlugin.java`, so it is a constant both sides have to agree on: declare it once in `packages/api` and have the TypeScript read it from there, and leave a comment in the Java naming the TypeScript constant it must match, since Java cannot import it. Correct the comment in `plan-sync.worker.ts` that says the WebView never learns the source, which is what stopped this being done in the first place. Unit test the plan builder's tag. Compile and tests pass.

5. **Check the native driver treats a cancelled step as a pass to retry, not a reason to stop.** `SyncDriver.performPass` in `apps/android-frontend/.../SyncDriver.java` runs the plan's steps through `runStep`, which returns false when the task did not succeed. Read what the driver then does, and make sure a cancelled step leaves `passRunning` cleared, the driver un-stopped, and the loop waiting for the next interval exactly as it would after any other pass. The driver's own `stop()` is a different thing and must stay that way: it ends the loop, and cancelling one pass must not.

6. **Cover it end to end.** Extend `apps/smoke-tests/tests/50-background-sync/test.sh`, which already drives a real sync against an S3 origin: while a sync is running, cancel it from the jobs list (the row's Cancel, reached from the navbar jobs indicator), assert the job row clears, and assert that a later pass syncs the photo anyway, which is what proves cancelling stopped one pass rather than switching syncing off. On the desktop, add the same to `apps/desktop/smoke-tests` beside the existing sync coverage. Watch both fail first, by asserting against the code before step 1.

7. **Update the documentation to match the code**, including exactly what a cancelled pass does to the state files and how long until the next one starts. The documents affected are `docs/background-tasks.md`, whose passage saying a background sync deliberately has no cancel is now wrong, and `docs/syncing.md`.

## Unit Tests

- `syncDatabases` (`packages/node-api/src/test/lib/sync.test.ts`, creating it if it does not exist): stops when the callback reports cancellation before a phase; stops between files in a push; releases both write locks when it stops; does not stamp the state files as synced when it stops early.
- `syncDatabaseHandler` (`packages/node-api/src/test/lib/sync-database.worker.test.ts`): passes a cancellation callback through to the sync; reports the cancelled outcome rather than a failure; still returns the "no origin" and "origin unreachable" early-outs unchanged.
- The plan builder in `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts`: the job tag carries the cancel source, and it is the shared constant rather than a literal typed twice.
- No unit test for `enqueueSyncTask` or the jobs dialog: the first is Electron main-process wiring covered by the desktop smoke test, the second is a React component.

## Smoke Tests

- `apps/smoke-tests/tests/50-background-sync`: a sync cancelled from the jobs list stops, the job row clears, and a later pass moves the photo to the origin anyway.
- `apps/desktop/smoke-tests`: the same, plus that a second sync is queued after a cancelled one, which is what catches the `isSyncRunning` flag being left set.
- Both suites' existing sync assertions must keep passing, which is what proves an uncancelled sync is unchanged.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- The jobs list shows a Cancel on the "Syncing database" row on both desktop and mobile, and pressing it clears the row without switching syncing off in Configuration.

## Notes

- **The stated reason for leaving the cancel out is only half true.** The desktop already queues the sync under `currentDatabasePath`, a source the interface knows, so nothing was ever stopping it there. On mobile the source is `BACKGROUND_SYNC_TASK_SOURCE`, a fixed constant in the Java, and the WebView's `cancelTasks` forwards to the same engine pool the native driver queues into, so it can reach it. The comment saying the WebView never learns the source is wrong, and correcting it is part of step 4.
- **The real gap is that nothing checks for cancellation.** Neither `sync.ts` nor `sync-database.worker.ts` mentions it, so a Cancel button added on its own would drop a queued sync and let a running one carry on to the end, which is worse than no button: the row would disappear while the upload continued.
- **A half-finished sync is already a supported state.** `docs/syncing.md` says a sync interrupted part way leaves both databases valid and the next one works out what is still missing by looking, because what moves is decided by comparing merkle trees rather than by a queue of pending work. That is what makes "just stop it" safe to implement, and it is why the state files must not be stamped on the way out.
- **Restarting is already the behaviour of both loops.** The desktop syncs every five minutes and after a debounced edit; the mobile driver runs a pass, pauses and runs another. Nothing new is needed for the restart, provided a cancelled pass leaves no flag set: `isSyncRunning` on the desktop and `passRunning` on the driver are the two to check.
