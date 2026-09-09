# Count the work in a job and estimate the time left

## Overview

A job row says what it is called, how long it has been going and a sentence about what it is doing, and nothing about how much is left. `IJobProgressMessage` carries a free-text `progressMessage` and nothing else, so even the jobs that know their own total (a consolidation plans the whole push before it starts; a prefetch builds the list of missing files; a sync knows what differs once the trees are compared) throw that number away by formatting it into a sentence. The result is a phone that looks stopped for long stretches while it is working, which is exactly what happened waiting for a partial replica to prefetch several thousand thumbnails with nothing on screen but an elapsed clock. This carries the counts through the job mechanism as numbers, works out the time remaining from them, and shows it. The estimate is deliberately pessimistic at the start and converges: the naive figure is doubled when nothing has been done and interpolated down to the plain average as the count approaches the total, so a user watching it sees the number fall rather than climb.

## Issues

## Steps

1. **Carry the counts through the message.** In `packages/task-queue/src/lib/types.ts`, add optional `completed` and `total` numbers to `IJobProgressMessage`, commented as the count of things finished and the count expected, both absent when the handler cannot know them. In `packages/task-queue/src/lib/job-progress.ts`, give `sendJobProgress` an optional counts argument and put it in the message. Both must stay optional: most handlers cannot know a total, and a handler that guessed one would be worse than one that said nothing. Unit tests for `sendJobProgress` covering with and without counts. `bun run compile` and `bun run test` must pass before this step is finished.

2. **Keep the counts on the job.** In `packages/user-interface/src/lib/jobs.ts`, add `completed` and `total` to `IJob` and carry them in `applyJobProgress`, which is the reducer that folds a progress message into the list. A message without counts must leave whatever the last one reported in place rather than clearing it, so a handler that reports counts on some messages and not others does not make the row flicker. Unit tests for `applyJobProgress` covering counts arriving, counts absent on a later message, and counts changing.

3. **Write the estimator as a pure function.** Add `packages/user-interface/src/lib/job-estimate.ts` exporting a function that takes the completed count, the total and the elapsed milliseconds and returns the estimated milliseconds remaining, or undefined when it cannot say. The rule:
    - Undefined when the total is unknown, the total is zero or less, the completed count is zero or less (there is no rate yet), or the completed count has reached the total.
    - The average per item is the elapsed time divided by the completed count.
    - The naive estimate is the remaining items multiplied by that average.
    - The reported estimate is the naive one multiplied by a damping factor that is 2 when nothing is done and falls linearly to 1 as the completed count reaches the total.
    Export a second function that formats a duration for the row ("about 5m left"), reusing the units `formatElapsed` in `jobs.ts` already uses so the two readings on the row cannot disagree about what a minute looks like. Unit tests for both, including every undefined case, the damping at the start, the middle and the end, and a total of one item.

4. **Show it on the row.** In `packages/user-interface/src/components/jobs-dialog.tsx`, render the estimate beside the elapsed time, under its own `data-id` so the smoke tests can read it, and render nothing at all where the estimator returns undefined. The row already re-renders on a tick from `useElapsedTick`, so the estimate updates with the clock. Where counts are known, show the "X of Y" as well: that is the number the user can check the estimate against. React components get no unit test; step 5 covers this.

5. **Prove it with the test job.** `packages/node-api/src/lib/test-job.worker.ts` already takes a pretend item count and counts up to it, and is reachable from the Developer screen, so it is the one job that can be driven deterministically. Report its count and total through the new argument, then add a smoke test that starts a test job with a known duration and item count and asserts the row shows an "of" count and a falling estimate, and that the estimate is absent before the first item completes. Watch it fail first.

6. **Report counts from the jobs that already know their total.** One step each, smallest first, and each one only where the number is genuinely known rather than guessed:
    - **Prefetch** (`packages/node-api/src/lib/prefetch-database.worker.ts`): it walks the origin to find what is missing, so the total is known once that walk is done. This is the job whose silence prompted the plan, and it does not report progress at all today: give it a job tag as well as counts.
    - **Sync** (`packages/node-api/src/lib/sync.ts` and `sync-database.worker.ts`): the number of files to move is known once the trees are compared, before any of them moves.
    - **Replicate** (`packages/node-api/src/lib/replicate.ts`): the merkle tree's leaf count is the total, known before the first copy. The existing comment calling its progress indeterminate is what this step removes.
    - **Import** (`packages/node-api/src/lib/import-assets.worker.ts`): no total until the source has been walked, and the scanner already reports when that has happened. Report the count alone until then and both afterwards.
    - **Consolidate** (`packages/node-api/src/lib/consolidate-database.worker.ts`): it already knows pushed and total and already streams them, but as its own message type consumed only by its dialog. Move it onto the job mechanism so it is one row like everything else.
    Each of these is its own step: change the handler, unit test the counting, and confirm the row shows a total for that job.

7. **Update the documentation to match the code**, including which jobs report a total and which cannot, and the exact wording the row shows. The document affected is `docs/background-tasks.md`, whose "Surfacing a task as a job" section describes what a handler reports.

## Unit Tests

- `sendJobProgress` (`packages/task-queue/src/test/lib/job-progress.test.ts`): sends the counts when given, omits them when not, still does nothing without a job tag.
- `applyJobProgress` (`packages/user-interface/src/test/lib/jobs.test.ts`): counts arrive, counts persist when a later message omits them, counts update, a job with no counts is unchanged.
- The estimator (`packages/user-interface/src/test/lib/job-estimate.test.ts`): undefined for an unknown total, a zero total, a zero completed count and a completed count at the total; the doubling at the first item; the damping halfway; the plain average at the last item; a one-item total.
- The formatter, in the same file: seconds, minutes, hours, and a value under a second.
- The counting in each handler changed by step 6, in that handler's existing test file: the total reported is the number of things it is about to work through, and the completed count rises by one per item.
- No unit tests for `jobs-dialog.tsx`: React components are covered end to end.

## Smoke Tests

- A new mobile test driving the test job from the Developer screen: the row shows "X of Y", the estimate appears once the first item completes, and the estimate is smaller later in the run than it was at the start.
- The same on the desktop, beside the existing job manager coverage.
- `apps/smoke-tests/tests/36-prefetch-database`: the prefetch now shows a job row with a total, which is the case the plan exists for.

## Verify

- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:and` passes.
- `bun run test:electron` passes.
- `bun run tev` passes, in one run, as the final check.
- Driving a test job of a known length from the Developer screen shows an estimate that starts high and falls, and lands within the run's actual duration rather than overshooting it at the end.

## Notes

- **Why the doubling.** An average taken over a handful of items is a bad predictor, and the first items of a job are often the fastest (caches cold, no contention) or the slowest (setup). Starting at twice the naive figure and converging on it means the number a user sees usually falls, and a falling estimate reads as progress while a rising one reads as the app not knowing what it is doing. It does not make the estimate correct early; it makes it wrong in the direction that is easier to live with.
- **The estimate can still rise**, and the plan does not pretend otherwise: a job that genuinely slows down (a phone throttling, a network degrading) will see its average worsen faster than the damping falls. Nothing here smooths that, and nothing should hide it.
- **The average is taken over the whole run**, as asked, rather than over a recent window. A windowed rate reacts faster to a change in speed and is noisier on a job that moves items of very different sizes, which is most of these: one photo is a thumbnail and the next is a video. If the whole-run average proves too sluggish in practice, that is the first thing to revisit.
- **Counting items is not counting bytes.** A sync moving 100 thumbnails and one 4GB video will report 101 items and estimate badly. Reporting bytes as well would fix it and is deliberately not in this plan: it doubles the reporting surface, and the item count is what every one of these handlers already has to hand.
- **`test-job.worker.ts` is the only job that can be driven deterministically**, which is why step 5 comes before the real handlers: it makes the interface and the estimator testable without staging a large database.
