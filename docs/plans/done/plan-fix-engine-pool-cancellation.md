# Fix the mobile engine pool remembering a cancelled source forever

## Overview

The mobile background engine pool keeps a set of cancelled task sources and never removes anything from it. Cancelling a source once means every task queued under that source afterwards is discarded before it runs, silently, for the rest of the app's life.

The fix is small: queueing a task from the WebView clears that source from the set. This plan makes that change on Android and iOS, with unit tests.

## Why this is worth doing (read this before deleting the plan)

**Two things a user does routinely are broken by it.**

- Replicating a database a second time does nothing. `replicateDatabase` in `packages/node-api/src/lib/replicate-database.ts` tags its queue with the source database's path and calls `shutdown()` when it finishes, and `TaskQueue.shutdown()` calls `backend.cancelTasks(this.source)`. So a successful replication cancels its own source as its last act. Every later replication of that database is dropped before it starts.
- Browsing an S3 bucket a second time shows an empty list. Closing the browser shuts down its queue, which cancels the listing source. The next browse is discarded.

**There is no error in either case.** The task is dropped inside the native pool before dispatch. Nothing rejects, nothing logs, the UI simply shows nothing and waits. From the user's side the feature silently stopped working, and restarting the app is the only cure. That is the worst failure mode available: no message, no log line, and a state that persists.

**It only affects mobile.** The Bun, Electron and inline pools cancel what is running and drop what is pending, and keep no memory of the source afterwards. The mobile pool is the only backend that holds a `cancelledSources` set at all, so `TaskQueue.shutdown()` means something different there than everywhere else. Mobile is the platform whose background work is hardest to observe, which is why it survived.

**Working around it is worse, and has already been tried.** The obvious workaround is to give each queue a unique throwaway source tag so cancellation never collides. That was done in two places and it hides the fault rather than fixing it: the pool still poisons any source it is given, so the next person to use a stable source tag gets the same silent breakage with no clue why. It also spreads: one workaround becomes two becomes a convention nobody can remove. `checkDatabaseExists` already carries a unique tag for this reason, which is how the pattern started.

**The fix is about six lines per platform** and is covered by existing smoke tests once they exercise a second replication.

## Issues

## Steps

Each step must leave `bun run compile` clean and `bun run test` passing before it is done.

### Step 1: Confirm the fault and the semantics

Read `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/EnginePool.java` and record:

- `cancelledSources` and every place it is read or written.
- `addTask`, which drops a task when its source is in the set.
- `queueChildTask`, which does the same for a task spawned by a running handler.
- `cancelTasks`, which adds to the set.
- `shutdown`, which is the only place the set is cleared.

Confirm the same shape in `apps/ios-frontend/ios/App/App/JsEngine/EnginePool.swift`. Record any difference between the two: they are meant to be equivalent and a divergence is a separate finding worth reporting.

The intended semantics, which the fix must implement: **cancelling a source cancels the work in flight at that moment, and nothing more.** It must not disable the source for future work.

### Step 2: Clear the source when a task is queued from the WebView

In `EnginePool.addTask` (Android) and `EnginePool.addTask` (iOS), replace the check that drops the task with removal of the task's source from `cancelledSources`, then enqueue as normal.

A task queued from the WebView is a fresh, deliberate request from the app, so it re-arms its source.

**Leave the check in `queueChildTask` exactly as it is.** Children are spawned from inside a running handler, so a batch that is being cancelled right now can still be producing them, and they must still be dropped. This is the reason the set exists and the reason the fix is in `addTask` alone. Removing the check from both places would break cancellation.

Add a comment above each change stating why `addTask` clears and `queueChildTask` does not, because the asymmetry is not obvious and will otherwise be "tidied up" later.

### Step 3: Remove the workarounds the fault forced

Once the pool is correct, revert the unique-source tags that exist only to dodge it, so the code says what it means:

- `replicateDatabase` in `packages/node-api/src/lib/replicate-database.ts`: use the source database's path as the queue source.
- Any S3 directory listing source in `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`: use the stable source tag.
- `checkDatabaseExists`: check whether its unique tag exists for this reason, and if so revert it too. If it has a different reason, leave it and record the reason.

Each revert must be verified by the smoke tests in the next step, not assumed.

### Step 4: Prove it with a test that fails before the fix

Extend the mobile replication smoke test to replicate the same database twice in a row and assert the second replication produces its result, not silence.

Confirm this addition fails against the pre-fix pool and passes after. A test that passes both ways is not testing this fault, and without it nothing stops the fault returning.

Do the same for the S3 browser if `plan-s3-smoke-tests-minio.md` has landed: browse a bucket, close the browser, browse again, and assert the listing appears the second time.

## Unit Tests

The pool is Java and Swift, and the repository has no unit test harness for either, so the behaviour is covered by the smoke tests in step 4, in line with how the other native host functions are covered.

For the TypeScript side:

- `packages/node-api/src/test/replicate-database.test.ts`: assert `replicateDatabase` constructs its `TaskQueue` with the source database's path, so the step 3 revert cannot be silently undone.
- Any existing test asserting the unique-tag behaviour must be updated to assert the reverted behaviour rather than deleted, so the intent stays recorded.

## Smoke Tests

- Mobile replication test: replicate twice, assert the second run works. New assertion, must fail before the fix.
- Mobile S3 browser test: browse twice, assert the second listing appears. Only if the S3 test exists.
- The existing mobile suite must stay green throughout: the fix changes when tasks are dropped, so a regression would show as a cancelled task running when it should not.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:and` is fully green.
- `bun run test:all` is fully green, confirming the step 3 reverts did not disturb desktop or CLI.
- The new double-replication assertion fails against the pre-fix pool. Record this; it is the proof the fix addresses the stated fault.
- `git grep -n "uuidGenerator.generate()" packages/node-api/src/lib/replicate-database.ts` returns nothing, confirming the throwaway tag is gone.
- Cancelling still works: a replication cancelled part way stops, and its child tasks do not continue.

## Notes

- **Proper fix, not a workaround.** Do not reintroduce unique source tags. If a case appears where re-arming on `addTask` is wrong, that is a design question to raise, not a reason to sidestep the pool again.
- Keep the diff minimal: two small changes in `EnginePool.java` and `EnginePool.swift`, plus the step 3 reverts. Nothing else in the pool needs touching.
- Android and iOS must end up with matching behaviour. If step 1 finds they already differ, report it rather than quietly making one match the other.
- The asymmetry between `addTask` and `queueChildTask` is the heart of this fix. Anyone reading it later must be able to see why, which is what the step 2 comments are for.
