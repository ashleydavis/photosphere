# Keep the App Responsive While Importing

## Overview

Automatic import currently takes the whole machine. On a Pixel 6 with 2,300 photos in the library, tapping a database took 2 minutes 8 seconds to open, and a photo taken with the camera did not appear for 42 minutes. Neither is a slow disk or a slow phone: the import queues one task per file with nothing holding it back, all tasks share a single first-come-first-served queue with no notion of who is waiting, and the loop only looks for new photos between batches of up to 60. This plan makes the work the user is waiting on go first, caps how much import work can be in flight, and shrinks the batch so new photos are noticed in seconds.

## Issues

## Steps

1. **Add a priority to the task queue interface.** Extend `addTask` in `packages/task-queue/src/lib/queue-backend.ts` and `packages/task-queue/src/lib/task-queue.ts` with a priority argument. Two levels are enough: interactive (something the user is waiting on) and background (everything else). Default to background so no existing caller changes behaviour by accident. Update the `IQueueBackend` implementations: `packages/task-queue/src/lib/worker-queue-backend.ts`, `packages/mobile-frontend/src/lib/embedded-js-queue-backend.ts`, the Electron and WebSocket proxies, and the inline pool.

2. **Make the pending queue honour the priority.** In `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/EnginePool.java` and `apps/ios-frontend/ios/App/App/JsEngine/EnginePool.swift`, change the single pending FIFO so an interactive task is dispatched ahead of background ones while keeping arrival order within each level. Both `addTask` and `queueChildTask` feed the same queue, and child tasks must inherit their parent's priority so an import's children cannot jump ahead of a user's tap. Do the same for the desktop worker pools in `packages/node-api`.

3. **Reserve an engine for interactive work.** Even with priority, an interactive task still waits for a running background task to finish, and a hash of a large photo is not quick. In both engine pools, keep one engine that background tasks may not occupy while any interactive task is pending. Note that `asset-server` and `auto-import` each hold an engine for the life of the app, so the reservation must be counted against the engines that actually cycle.

4. **Mark the user-facing tasks interactive.** Tag the tasks raised in response to a tap: the database load path in `packages/user-interface/src/context/asset-database-source.tsx`, the databases-config reads in `packages/mobile-frontend/src/lib/mobile-databases-config-file.ts`, and the asset reads the gallery makes while scrolling. Everything automatic import raises stays background.

5. **Cap how many import children run at once.** `packages/node-api/src/lib/import-assets.worker.ts` queues a `hash-file` task for every file the scan finds, as fast as it can scan, then waits for them all. Add a concurrency limit so only a fixed number are in flight, queueing the next as each completes. The limit is 2 on mobile and 10 on desktop. Pass it in as task data from the caller rather than reading the platform inside the worker, so the worker stays platform-free and the limit is testable.

6. **Shrink the import batch.** The batch is up to 60 because the backfill rate is 60 items a minute and the budget is capped at one minute's worth (`packages/api/src/lib/auto-import-queue.ts`). Add an explicit maximum batch size, much smaller than 60, and apply it in `nextBatch`. Somewhere around 5 keeps the loop coming back to look for new photos every few seconds at the observed import rate. Leave the per-minute rate alone: it is the pacing, and the batch size is a separate thing that was never bounded.

7. **Look for new photos while a batch is running.** In `packages/api/src/lib/auto-import-loop.ts` the main loop only calls `collectArrivals` at the top, so nothing looks for new photos for as long as `importBatch` is awaited. Restructure so the arrival walk can run while a batch is in flight, or so a batch is interrupted when the watcher reports a change. The arrival walk itself lists every page of the library, which is 2,300 items on the test device, so it must not run more often than the watcher's poll interval.

8. **Put new photos in front of the backfill.** `nextBatch` already puts fast-lane items at the head of the batch. Once step 7 lets arrivals be found mid-import, make the next batch after an arrival carry the fast-lane items alone rather than filling the rest of the batch with backfill, so a photo just taken is imported next rather than behind up to a batch of old ones.

Every step must compile (`bun run compile`) and leave the unit tests passing before it is considered done.

## Unit Tests

- `packages/task-queue/src/test/` — a task with interactive priority is dispatched before background tasks already queued; arrival order is kept within a priority; a child task inherits its parent's priority.
- `packages/node-api/src/test/lib/import-assets.worker.test.ts` — no more than the configured number of hash tasks are in flight at once; every file is still hashed; the limit is read from the task data.
- `packages/api/src/test/lib/auto-import-queue.test.ts` — `nextBatch` never returns more than the maximum batch size; the per-minute pacing still holds across several calls; fast-lane items still come first.
- `packages/api/src/test/lib/auto-import-loop.test.ts` — an arrival reported while a batch is running is picked up without waiting for the batch to finish; the arrival walk does not run more often than the poll interval; the batch after an arrival carries the fast-lane items ahead of backfill.
- The native engine pools have no unit test framework in this repository. Cover them with the smoke tests below.

## Smoke Tests

- Android and iOS suites in `apps/smoke-tests/`: with a seeded library large enough to keep the import busy, open a database and assert the gallery is showing within a few seconds. This is the 2 minute 8 second failure and is the test that proves it fixed.
- Android and iOS suites: with the import running, add a photo to the device library and assert it reaches the gallery within seconds rather than minutes.
- `bun run test:cli` and `bun run test:electron`: the import concurrency limit does not slow the desktop import or drop files. Compare the imported count against the input count on an existing import test.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes.
- `bun run test:everything -- --force` passes.
- On a device with a large library mid-import: a database opens in seconds, and a photo taken with the camera appears in the gallery within seconds.

## Notes

- The three causes are separate and each is enough to cause the delay on its own: unbounded child tasks filling the queue, no priority so a tap sits behind them, and a batch large enough that the loop is blind to new photos for ten minutes at a time. Fixing one and not the others will not give the result.
- Measured during testing: 143 of 143 hashes computed from scratch, 5 engines with 2 permanently held, batches of 50 to 60, and an import rate of about 5 photos a minute. The hash cache is a separate plan and fixing it will raise the import rate, which shortens a batch but does not remove the need for priority.
- Steps 1 to 3 change a shared interface and both native pools, so they touch desktop as well as mobile. Desktop has more workers and a faster disk and does not show the problem, but the same code paths are used and must keep working.
- Open question for step 3: whether one reserved engine is enough, or whether the reservation should scale with the pool size. Start with one and measure.
- Open question for step 7: interrupting a batch part way needs care about the write lock the import takes and about the backfill cursor, which is only advanced once a page has been released in full. Running the arrival walk alongside the batch is likely simpler than interrupting it.
