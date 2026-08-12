# Halve the duration of `bun run test:and`

## Overview

`bun run test:and` runs 43 mobile smoke tests across the five pool emulators. Measured from the run on 2026-08-12 13:41, the tests themselves consumed 600 seconds of work and the test loop took about 150 seconds of wall clock, on top of a prologue (Capacitor sync, Gradle assemble, per-device APK install) that was 11 seconds when the build was warm and every emulator already carried this build. The aim is a full `test:and` at around 3 minutes, reached without deleting a test, weakening an assertion, skipping a test by default, or shortening a wait that a test genuinely depends on. Every saving in this plan comes from one of three places: work that is waited for but never needed, work that is done serially when it could be done at once, and scheduling that leaves emulators idle while a long test runs alone at the end.

The measured facts this plan is built on:

- 43 tests, 600 seconds of total test work, five emulators. Perfect packing gives a 120 second loop, so the theoretical floor with today's tests is about 120 seconds plus the prologue.
- The loop actually took about 150 seconds. The gap is tail latency: tests are dispatched in numbered order and the three longest tests are the highest-numbered, so `37-lan-share-timeout` (76s), `43-s3-failure` (72s) and `45-s3-share-replica-sync` (53s) all started near the end. From 13:43:22 to 13:44:11 only those three were running and two emulators sat idle.
- The `.slow` ordering marker described in `docs/plans/done/plan-faster-android-tests.md` is no longer in `apps/smoke-tests/lib/runner.sh`: `run_pool` dispatches strictly in queue order and `order_tests` does not exist. Re-introducing longest-first dispatch is the single cheapest win available.
- The five longest tests are `37-lan-share-timeout` 76s, `43-s3-failure` 72s, `45-s3-share-replica-sync` 53s, `21-import-video` 26s, `42-s3-sync-prefetch` 25s. Those five are 252s of the 600s.
- `37-lan-share-timeout` is `.exclusive` and deliberately waits out the real 60 second LAN-share window from `SHARE_TIMEOUT_MS` in `packages/node-api/src/lib/lan-share.worker.ts:17`. It is the longest single test and therefore the hard floor on the loop.
- Every test pays a fixed prologue of its own: `pm clear` on the way in (`android_reset_app_state`), a fresh control bridge, a cold `am start`, `wait_for_ready`, then `stop_app` and a second `pm clear` on the way out (`android_clean_after_test`). `stop_app` goes through `kill_process_group`, which sleeps a fixed `PROCESS_CONTROL_TERM_GRACE_SECONDS` (1 second) between SIGTERM and SIGKILL whether or not the process has already gone. Across 43 tests that is 43 seconds of pure sleeping inside the 600s of work.
- The per-device loops in `apps/smoke-tests/run.sh` (`${PLATFORM}_ensure_apk` before the pool, `cleanup_all_devices` from the EXIT trap) walk the five emulators one at a time. A reinstall is 117MB per device, and a run that follows another worktree's run reinstalls on all five.

The plan is deliberately ordered so that the measurement step comes first and every later step is accepted or abandoned on a measured number, exactly as `docs/plans/done/plan-faster-android-tests.md` did. Steps 3 to 8 are ranked by expected saving. If the measured baseline turns out to be dominated by something this plan did not predict, step 1's output says so before any code is changed.

## Issues

## Steps

Each step carries a checkbox and a status: `not started`, `completed`, or `abandoned`. Tick the box and update the status as the step is finished. A step is complete only when `bun run compile` is clean, `bun run test` passes, and the step's own verification below has been run and its measured numbers written into the step.

1. [ ] **Instrument the run so every later step is measured, not estimated.** Status: not started.

    In `apps/smoke-tests/run.sh`, record `SECONDS` at three points in `main`: entry, immediately after `with_build_lock "${PLATFORM}_build"` returns, and immediately after the `usable_slots` install loop finishes. After the pass/fail summary, print a timing block: build seconds, install seconds, loop seconds, total seconds, the sum of every test's recorded duration, the count of tests, and the ten slowest tests with their durations, sorted descending. The per-test durations are already written to `<test temp dir>/test-duration.txt` by `run_test` and their paths are already in the result files, so the block is assembled from the result files that the summary loop already reads. Also print "packing efficiency": sum-of-test-seconds divided by (loop seconds times worker count), which is the number that says whether the emulators were kept busy.

    Add the same block to `apps/smoke-tests/lib/runner.sh` only if it needs data the results directory does not already carry; prefer keeping the change inside `run.sh`.

    Then capture the baseline: run `bun run test:and` three times with the pool up and nothing else running, and record the three timing blocks in this step. Then run it once more immediately after touching a file under `packages/user-interface/src/` so the Vite build and Gradle assemble are cold, and record that too. This gives both the warm number and the number a real change produces. No step below may claim a saving that is not the difference between two of these blocks.

    This is shell only, so per the repository rules it gets no shell test. It is verified by the numbers it prints matching the wall clock of the run that printed them.

2. [ ] **Re-introduce longest-first dispatch.** Status: not started. Expected saving: 20-40s of loop, from the measured 150s loop against a 120s perfect-packing floor.

    In `apps/smoke-tests/lib/runner.sh`, add `order_tests <test_path...>`, which prints the given test paths with `.slow`-marked ones first and the relative order of everything else unchanged, with the `#` comment block this repository uses. Call it from `run.sh` on the selected test list before `run_pool`. Create empty `.slow` marker files in `apps/smoke-tests/tests/37-lan-share-timeout/`, `43-s3-failure/`, `45-s3-share-replica-sync/`, `21-import-video/` and `42-s3-sync-prefetch/`, which are the five tests measured above 25s.

    `37-lan-share-timeout` is both `.slow` and `.exclusive`, and it must be the very first entry: it cannot overlap another exclusive test, so any exclusive test that starts before it pushes the 76s window later and lengthens the tail. Have `order_tests` emit `.slow`-and-`.exclusive` tests first, then the remaining `.slow` ones, then the rest.

    Document the `.slow` marker in `apps/smoke-tests/tests/README.md` beside `.exclusive`, saying it is an ordering hint only and never changes what a test does.

    Complete when a full `bun run test:and` passes 43/43 and the timing block shows a shorter loop and a higher packing efficiency than the step 1 baseline.

3. [ ] **Stop `stop_app` sleeping a fixed second per test.** Status: not started. Expected saving: up to 43s of the 600s of test work, which at five workers is roughly 8s of loop, and more where it lands on the critical path.

    In `scripts/lib/process-control.sh`, change `kill_process_group` and `kill_process_tree` to poll for the process being gone instead of sleeping the full `PROCESS_CONTROL_TERM_GRACE_SECONDS` unconditionally: after SIGTERM, check every 100ms up to the existing grace period and return the moment nothing in the group or tree is alive, only sending SIGKILL when the grace period genuinely expires. Keep the constant and its comment; it becomes the ceiling rather than the cost.

    This helper is shared by every suite in the repository (CLI, desktop, mobile), so its behaviour must not change in any other respect: the same signals in the same order, the same descendants reached, the same return value.

    Per the repository rules this shell helper gets no new shell test. It is covered end to end by the suites that use it, so completion requires `bun run test:everything -- --force` to pass, not just `test:and`.

4. [ ] **Install and clean the emulators concurrently instead of one at a time.** Status: not started. Expected saving: measured from step 1's install seconds; on a run following another worktree's run this is five sequential 117MB installs.

    In `apps/smoke-tests/run.sh`, change the `${PLATFORM}_ensure_apk` loop and `cleanup_all_devices` so each device is handled in a background job and the loop waits for all of them, recording each job's pid at the moment it is started and collecting each one's exit status. Every device already takes its own lock through `with_device`, and `ANDROID_SERIAL` is exported per invocation, so the devices do not contend with each other. A device that returns `DEVICE_UNAVAILABLE_STATUS` must still be dropped from `usable_slots` exactly as it is today, and any other non-zero status must still fail the run.

    Complete when a run whose emulators carry another build reinstalls on all five and the timing block's install seconds are close to the slowest single install rather than their sum.

5. [ ] **Find and remove the dead waiting inside the four longest non-LAN tests.** Status: not started. Expected saving: the largest single lever on total work; `43-s3-failure`, `45-s3-share-replica-sync`, `21-import-video` and `42-s3-sync-prefetch` are 176s of the 600s between them.

    For each of `apps/smoke-tests/tests/43-s3-failure/test.sh`, `45-s3-share-replica-sync/test.sh`, `21-import-video/test.sh` and `42-s3-sync-prefetch/test.sh`, in that order: run it alone with `bun run test:and -- <number>`, read its `test-run.log` and `app.log` with timestamps, and account for every block of more than two seconds. Write the account into this step, then remove only the waits that are proven to be waiting for something that has already happened. In particular:

    - Replace any fixed `sleep` that is standing in for an observable condition with the existing `wait_for_log`, `wait_for_value` or `android_wait_for_file` helper, which poll five times a second. The fixed sleeps to look at first are `43-s3-failure/test.sh:107`, `45-s3-share-replica-sync/test.sh:139`, `26-receive-database/test.sh:55`, `27-receive-secret/test.sh:53` and `44-receive-database-cancel/test.sh:105`.
    - Check what `start_s3_emulator` costs in `43`, `42` and `45`, and whether the test waits for the emulator to be listening or sleeps at it.
    - Do not touch a wait that a test's assertion depends on, and do not shorten a retry or backoff window that the code under test genuinely takes. Where a wait is real, say so in this step and leave it.

    Each edited test must pass on its own and inside a full run, and its recorded duration must be lower than the step 1 baseline for that test. A test whose duration does not fall gets its finding written down and is left alone.

6. [ ] **Cut the per-test app start and stop overhead.** Status: not started. Expected saving: 43 tests times whatever the measurement shows; every second removed here is 43s off total work and roughly 8s off the loop.

    Measure first, inside one representative test (`5-add-secret`, which is 8s and does almost nothing else): timestamp `android_reset_app_state`, the control bridge start, `android_launch`, `wait_for_ready`, `stop_app` and `android_clean_after_test`, and record the six numbers in this step. Then act only on what the numbers show, choosing from:

    - `android_clean_after_test` runs `pm clear` after every test, and `android_reset_app_state` runs it again at the start of the next one. The second clear on the way out exists to stop the emulators filling with imported photos and video thumbnails, which is real. If it is measurably expensive, make it run in the background with its pid recorded so the worker does not wait on it, while still holding the device lock until it finishes; do not simply delete it.
    - `wait_for_ready` polls `/ready` five times a second already, so it is unlikely to hold dead time, but confirm from the log rather than assume.
    - The control bridge is a `bun` process started per test. If its start-up dominates, record that finding here; do not share one bridge between tests, because that is exactly the isolation the suite depends on.

    Do not extend the app with anything that exists only to make tests faster: no test-only launch flags, no seeding hooks, no new IPC. If the only remaining saving needs something in the app, stop and put the question to the human in this step rather than writing it.

7. [ ] **Decide what to do about the 76s floor in `37-lan-share-timeout`.** Status: not started. Expected saving: up to 60s off the longest single test, which is the floor on the loop once packing is fixed.

    After steps 2 to 6, re-read the timing block. If `37-lan-share-timeout` is the longest test and the loop is within ten seconds of its duration, it is the floor and this step is worth doing; if the loop is well above it, record that and abandon this step.

    The window comes from `SHARE_TIMEOUT_MS` in `packages/node-api/src/lib/lan-share.worker.ts:17`, which is compiled into the mobile worker bundle. Making it configurable means plumbing a value from the launch intent through the `JsEngine` plugin into the embedded worker, which is a change to the app's configuration surface and would exist only for the tests. That is exactly the kind of test-only scaffolding this repository requires the human to approve first. So this step's deliverable is not code: it is a written proposal in this plan naming the exact files that would change, what the test's `< 50s` assertion would become (the regression it guards against collapsed 60s to about 12s, a 5x ratio that a 20s window still catches at `< 16s`), and the alternative of leaving the window alone. Stop there and wait for the human's answer.

8. [ ] **Update the docs with the new numbers and markers.** Status: not started.

    In `docs/testing/README.md`, record the measured `test:and` duration before and after, the `.slow` marker's meaning, and the timing block `run.sh` now prints. In `apps/smoke-tests/tests/README.md`, document `.slow` beside `.exclusive`. Do not describe any saving that was not measured in step 1's format.

## Unit Tests

Every code change in this plan is shell, and this repository forbids writing tests for shell scripts, so no `*.test.sh` file is created and none of the existing ones is extended.

- No TypeScript function is added or changed by steps 1 to 6, so no Jest test is added or changed. `bun run test` must still pass unchanged after every step, which is what proves that.
- Step 7 produces a written proposal and no code, so it carries no tests. If the human approves it later, the plumbing it describes is TypeScript and will need its own plan with unit tests for every function it adds.
- The existing `apps/smoke-tests/runner.test.sh` covers the queue and the exclusivity lock. Step 2 adds `order_tests` to the same file's subject matter, and the repository rule against new shell tests means it is not tested there; it is proven instead by the dispatch order visible in a real run's `RUN` lines, which step 2 requires to be checked.

## Smoke Tests

The mobile suite is itself the end-to-end coverage, and this plan changes only the harness that runs it and the waits inside four tests, so the whole existing suite is the regression check.

- `bun run test:and` passes 43/43 after every step, with no test skipped. The skip count printed by `run.sh` must be zero, and any test that reports `SKIP` is a failure of the step that caused it.
- `bun run test:and -- 43`, `-- 45`, `-- 21` and `-- 42` each pass alone after step 5, and each one's recorded duration is lower than its step 1 baseline.
- `bun run test:and -- 37` still measures a real window of at least 50s, proving step 2's reordering did not let another LAN test overlap it.
- `bun run test:cli`, `bun run test:cli:lan-share` and `bun run test:electron` pass after step 3, because `scripts/lib/process-control.sh` is shared by all of them.
- `bun run test:parallel` passes, proving the reordering and the concurrent install did not introduce contention between suites.
- Two `bun run test:and` runs started at the same time from two worktrees both pass, which is what step 4's concurrent install must not break.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:everything -- --force` passes, which is the canonical check and the only one that covers the CLI, desktop and mobile suites together after the shared `process-control.sh` change.
- `bun run test:and` passes 43/43 with zero skips, three times in a row.
- The timing block printed by `run.sh` shows a total at or below 180 seconds on a warm build with five emulators, against the step 1 baseline recorded from the same machine and the same pool.
- `bun run test:parallel` reports nothing failing in company.

## Notes

- **Where the current time goes, measured.** From the 2026-08-12 13:41 run: 43 tests, 600s of test work, about 150s of loop across five emulators, 11s of prologue with a warm build and the same APK already on every device. Perfect packing of today's tests is 120s, so about 30s of the loop is tail latency and the rest is real work.
- **Why the target is reachable without weakening anything.** 180s of budget against a 120s packing floor leaves room for the prologue. Steps 2 and 4 attack the tail and the prologue without touching a single assertion. Steps 3, 5 and 6 lower the 600s of work by removing time spent waiting for things that have already happened, which is the same class of change as the poll-interval fix that took the suite from 375s to 276s in `docs/plans/done/plan-faster-android-tests.md`.
- **What this plan refuses to do.** No test is deleted, merged, split across fewer emulators, or made conditional. No assertion is loosened. No wait that the code under test genuinely takes is shortened. Nothing test-only is added to the app: step 6 says so explicitly and step 7 stops and asks rather than writing the plumbing it describes.
- **The measured duration depends on what else is running.** `suite_share` in `apps/smoke-tests/lib/runner.sh` gives a suite an even split of the emulators when other suites are registered, so the same run inside `bun run test:everything` has fewer emulators than a standalone `test:and` and will be slower. Every number in this plan must be recorded standalone, with the pool up and nothing else running, or it cannot be compared with the baseline.
- **The prologue is small when the build is warm and large when it is not.** The 11s figure was measured with Gradle and Vite already up to date. A run after a change under `packages/user-interface/src/` pays the full Vite build and a Gradle recompile, which step 1 measures separately. If that cold number turns out to dominate, it is a different problem from the one this plan solves and belongs in its own plan rather than being smuggled into this one.
- **`.slow` used to exist and was removed.** `order_tests` and the `.slow` marker were part of the completed `plan-faster-android-tests.md` but are not in `apps/smoke-tests/lib/runner.sh` today, and `apps/smoke-tests/tests/README.md` documents only `.exclusive`. Step 2 reinstates them. Whoever removed them left no note of why, so if a reason surfaces during step 2 it goes in the Issues section before the step is finished.
- **Test 37 is the floor and the plan says so rather than working around it.** At 76s it is longer than the 120s packing floor divided by nothing, and once packing is fixed the loop cannot go below it. Step 7 exists to put that choice in front of the human with the exact cost written down, not to make it quietly.
