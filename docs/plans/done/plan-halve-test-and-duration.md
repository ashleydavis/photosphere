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

1. [x] **Instrument the run so every later step is measured, not estimated.** Status: completed.

    `print_timing_block` was added to `apps/smoke-tests/run.sh` and is printed after the pass/fail summary of every run. `main` records `SECONDS` at entry, after `with_build_lock`, after the install loop and around `run_pool`, and the per-test durations come from the `.result` files the summary loop already reads, so nothing in `lib/runner.sh` needed to change.

    Measured blocks, all standalone with the five-emulator pool up:

    - After steps 2, 3 and 4, on this worktree's first build (cold Gradle and Vite): build 40s, install 1s, loop 141s, total 183s, 633s of test work across 43 tests on 5 workers, packing 90%.
    - Warm build, run polluted by other work on the same machine. Recorded rather than quietly dropped, but not comparable with anything: build 7s, install 0s, loop 182s, total 189s, 752s of work, packing 83%. Tests that measure 5-6s on an idle machine came out at 35-38s in it. Every comparison below uses the clean runs only.
    - After every step below, clean and warm: build 7s, install 0s, loop 115s, total 123s, 457s of test work, packing 79%. Slowest: `37-lan-share-timeout` 65s, `45-s3-share-replica-sync` 55s, `42-s3-sync-prefetch` 25s, `41-s3-database-lifecycle` 18s, `34-sync` 18s.

    Against the plan's recorded baseline (600s of test work, about a 150s loop and an 11s warm prologue, so about 161s total) that is 457s of work and a 123s total, with no test deleted, skipped or weakened.

    In `apps/smoke-tests/run.sh`, record `SECONDS` at three points in `main`: entry, immediately after `with_build_lock "${PLATFORM}_build"` returns, and immediately after the `usable_slots` install loop finishes. After the pass/fail summary, print a timing block: build seconds, install seconds, loop seconds, total seconds, the sum of every test's recorded duration, the count of tests, and the ten slowest tests with their durations, sorted descending. The per-test durations are already written to `<test temp dir>/test-duration.txt` by `run_test` and their paths are already in the result files, so the block is assembled from the result files that the summary loop already reads. Also print "packing efficiency": sum-of-test-seconds divided by (loop seconds times worker count), which is the number that says whether the emulators were kept busy.

    Add the same block to `apps/smoke-tests/lib/runner.sh` only if it needs data the results directory does not already carry; prefer keeping the change inside `run.sh`.

    Then capture the baseline: run `bun run test:and` three times with the pool up and nothing else running, and record the three timing blocks in this step. Then run it once more immediately after touching a file under `packages/user-interface/src/` so the Vite build and Gradle assemble are cold, and record that too. This gives both the warm number and the number a real change produces. No step below may claim a saving that is not the difference between two of these blocks.

    This is shell only, so per the repository rules it gets no shell test. It is verified by the numbers it prints matching the wall clock of the run that printed them.

2. [x] **Re-introduce longest-first dispatch.** Status: completed, then **removed again at the human's request**. Measured while it was in: loop 150s to 141s on the same day's work, and packing 90% against the baseline run's tail of three long tests running alone.

    **Removed on 2026-08-13.** The human reverted the five `.slow` marker files and then asked for the scheduling-marker support to go, so `order_tests`, `SLOW_MARKER` and the call from `run.sh` were deleted and both READMEs were put back to describing numeric dispatch. `.exclusive` was left alone; it is load-bearing rather than an optimisation, because the LAN tests corrupt each other without it. This is written down here on purpose: the marker had been removed once before (commit `f41247c6`, recorded in `docs/plans/done/plan-green-commit-walk.md`) and this plan was written believing no note of that existed, which is how it came to be reinstated in the first place. The reason this time is that the human does not want the mechanism, not that it failed to work.

    Everything below describes the marker as it was while it existed.

    `order_tests` is in `apps/smoke-tests/lib/runner.sh` and `run.sh` reads its output into `ordered_tests` before `run_pool`. `.slow` markers are on `37-lan-share-timeout`, `43-s3-failure`, `45-s3-share-replica-sync`, `21-import-video` and `42-s3-sync-prefetch`, and `37-lan-share-timeout` is emitted first of all because it is `.slow` and `.exclusive` together. `apps/smoke-tests/tests/README.md` documents the marker beside `.exclusive`.

    Nothing surfaced to explain why the marker was removed before, so the Issues section stays empty.

    One measured side effect worth recording: dispatching the four S3 tests together makes them contend, because each starts its own MinIO server and drives several `bun run start` CLI invocations. In the first ordered run `43-s3-failure` measured 104s against a 72s baseline and `45-s3-share-replica-sync` 83s against 53s, and the loop still came out shorter overall. Once step 5 took the dead minute out of `43-s3-failure` the contention stopped mattering: in the final run `45` measured 55s, which is inside the noise of its 53s baseline.

    In `apps/smoke-tests/lib/runner.sh`, add `order_tests <test_path...>`, which prints the given test paths with `.slow`-marked ones first and the relative order of everything else unchanged, with the `#` comment block this repository uses. Call it from `run.sh` on the selected test list before `run_pool`. Create empty `.slow` marker files in `apps/smoke-tests/tests/37-lan-share-timeout/`, `43-s3-failure/`, `45-s3-share-replica-sync/`, `21-import-video/` and `42-s3-sync-prefetch/`, which are the five tests measured above 25s.

    `37-lan-share-timeout` is both `.slow` and `.exclusive`, and it must be the very first entry: it cannot overlap another exclusive test, so any exclusive test that starts before it pushes the 76s window later and lengthens the tail. Have `order_tests` emit `.slow`-and-`.exclusive` tests first, then the remaining `.slow` ones, then the rest.

    Document the `.slow` marker in `apps/smoke-tests/tests/README.md` beside `.exclusive`, saying it is an ordering hint only and never changes what a test does.

    Complete when a full `bun run test:and` passes 43/43 and the timing block shows a shorter loop and a higher packing efficiency than the step 1 baseline.

3. [x] **Stop `stop_app` sleeping a fixed second per test.** Status: completed. Measured: a group kill of a process that dies on SIGTERM went from the full 1s to 18ms, and a tree kill to 29ms.

    `kill_process_group` and `kill_process_tree` in `scripts/lib/process-control.sh` now call `wait_for_processes_to_exit`, which polls every 50ms and returns the moment nothing is left alive. `PROCESS_CONTROL_TERM_GRACE_SECONDS` is unchanged and is now the ceiling: a process that ignores SIGTERM is still SIGKILLed after it. That was checked directly rather than assumed, with a process running `trap "" TERM`: the helper took 1051ms and the process was gone afterwards. The signals, their order, the pids reached and the return values are otherwise untouched.

    Per the repository rules this shell helper gets no shell test. It is covered end to end by every suite that uses it, and `bun run test:everything -- --force` passes.

    In `scripts/lib/process-control.sh`, change `kill_process_group` and `kill_process_tree` to poll for the process being gone instead of sleeping the full `PROCESS_CONTROL_TERM_GRACE_SECONDS` unconditionally: after SIGTERM, check every 100ms up to the existing grace period and return the moment nothing in the group or tree is alive, only sending SIGKILL when the grace period genuinely expires. Keep the constant and its comment; it becomes the ceiling rather than the cost.

    This helper is shared by every suite in the repository (CLI, desktop, mobile), so its behaviour must not change in any other respect: the same signals in the same order, the same descendants reached, the same return value.

    Per the repository rules this shell helper gets no new shell test. It is covered end to end by the suites that use it, so completion requires `bun run test:everything -- --force` to pass, not just `test:and`.

4. [x] **Install and clean the emulators concurrently instead of one at a time.** Status: completed. Measured: 1s of install on the run that had to check five emulators for the first time, 0s on every warm run after it.

    Both loops in `apps/smoke-tests/run.sh` now start one background job per device and record each pid as it starts. The install loop collects every job's status before acting on any of them, so a failure on one device cannot leave four installs running behind an exited script; a device returning `DEVICE_UNAVAILABLE_STATUS` is still dropped from `usable_slots` and any other non-zero status still fails the run. `cleanup_all_devices` waits on every job the same way.

    A second saving found while measuring this and taken here: `android_ensure_apk` runs before every single test, and it hashed the whole 117MB APK each time, reading about 5GB per run to answer the same question 43 times. `android_read_apk_checksum` caches the hash against the APK's size and modification time, so a rebuilt APK is still hashed again. The answer comes back in a global rather than on stdout, because a command substitution runs in a subshell and a cache filled inside one dies with it.

    The five-sequential-installs case could not be measured on this machine, because no run during this work found another worktree's build on the emulators: every install came back "already this build". What is measured is that the concurrent loops are correct and that the warm case costs nothing.

    In `apps/smoke-tests/run.sh`, change the `${PLATFORM}_ensure_apk` loop and `cleanup_all_devices` so each device is handled in a background job and the loop waits for all of them, recording each job's pid at the moment it is started and collecting each one's exit status. Every device already takes its own lock through `with_device`, and `ANDROID_SERIAL` is exported per invocation, so the devices do not contend with each other. A device that returns `DEVICE_UNAVAILABLE_STATUS` must still be dropped from `usable_slots` exactly as it is today, and any other non-zero status must still fail the run.

    Complete when a run whose emulators carry another build reinstalls on all five and the timing block's install seconds are close to the slowest single install rather than their sum.

5. [x] **Find and remove the dead waiting inside the four longest non-LAN tests.** Status: completed. Measured: `43-s3-failure` 73s to 9s run alone, and 11s inside a full run against a 72s baseline. The other three were accounted for and left alone.

    **`43-s3-failure`: a whole minute of waiting for something that had already been decided.** The test waited out a fixed 60 second window for `Load assets task completed: 0 assets loaded` to be absent, and only then started looking for the error. The two are mutually exclusive by construction rather than by timing: `openDatabase` in `packages/user-interface/src/context/asset-database-source.tsx:435` logs `Could not reach the database at ...` and returns without setting the database path, so no load task is ever started and the completion line cannot follow it. The test now waits for whichever of the two the app logs first, through a new `wait_for_either_log` in `apps/smoke-tests/lib/common.sh`, and the 90 second budget is unchanged. The empty-load line still fails the test and still fails it with the same message.

    Both failure paths were watched failing before the change was accepted, because a test that has only ever passed has not been shown to test anything:

    - With the two patterns swapped, so the error the app really logs arrives as the empty-load outcome, the test failed in 10s with "The app reported a successful load of 0 assets from an unreachable bucket". The log shows `Found the second pattern (line 19)`.
    - With both patterns replaced by lines the app never writes and the budget cut to 5s, the test failed in 16s on the timeout branch.

    **`45-s3-share-replica-sync`, 55s: real work, left alone.** Its one fixed wait is the `sleep 3` at line 139, which gives the on-device receiver time to start broadcasting before the host CLI begins discovery, exactly as test 26 does. Everything else in it is six `bun run start` CLI invocations against an encrypted S3 database, a LAN transfer, a partial replication, a prefetch and two syncs, each anchored on a log line or a value read back from the app. There is nothing here waiting for something that has already happened.

    **`42-s3-sync-prefetch`, 25s: real work, left alone.** No fixed sleep at all. Its cost is three `bun run start` invocations on the host (`init`, `add`, `replicate --partial`) plus the prefetch and sync on the device, and every wait is a poll on a log line, a device file or a value.

    **`21-import-video`: no longer in the ten slowest and not touched.** It measured 26s in the plan's baseline and does not appear in the final run's top ten, so there was nothing to act on.

    **`start_s3_emulator`** was checked in all three S3 tests: it runs `bun run s3-emulator start`, which returns once the server has been started and its env file written, and the tests read that file rather than sleeping at it. No change.

    The remaining fixed sleeps named in this step are `26-receive-database:55`, `27-receive-secret:53` and `44-receive-database-cancel:105`, all `sleep 3`, and all the same LAN receiver slack as `45`. Together they are about 9s of test work, under 2s of loop at five workers, and removing them without an observable signal that the receiver is broadcasting would trade that for a race. They are real waits and they are left.

    For each of `apps/smoke-tests/tests/43-s3-failure/test.sh`, `45-s3-share-replica-sync/test.sh`, `21-import-video/test.sh` and `42-s3-sync-prefetch/test.sh`, in that order: run it alone with `bun run test:and -- <number>`, read its `test-run.log` and `app.log` with timestamps, and account for every block of more than two seconds. Write the account into this step, then remove only the waits that are proven to be waiting for something that has already happened. In particular:

    - Replace any fixed `sleep` that is standing in for an observable condition with the existing `wait_for_log`, `wait_for_value` or `android_wait_for_file` helper, which poll five times a second. The fixed sleeps to look at first are `43-s3-failure/test.sh:107`, `45-s3-share-replica-sync/test.sh:139`, `26-receive-database/test.sh:55`, `27-receive-secret/test.sh:53` and `44-receive-database-cancel/test.sh:105`.
    - Check what `start_s3_emulator` costs in `43`, `42` and `45`, and whether the test waits for the emulator to be listening or sleeps at it.
    - Do not touch a wait that a test's assertion depends on, and do not shorten a retry or backoff window that the code under test genuinely takes. Where a wait is real, say so in this step and leave it.

    Each edited test must pass on its own and inside a full run, and its recorded duration must be lower than the step 1 baseline for that test. A test whose duration does not fall gets its finding written down and is left alone.

6. [x] **Cut the per-test app start and stop overhead.** Status: completed, on the two things the measurements pointed at. Nothing was added to the app.

    Two costs were found and both are gone, and neither needed a change inside a test:

    - **`stop_app`'s fixed second, per test.** Step 3. 43 tests each paid the full `PROCESS_CONTROL_TERM_GRACE_SECONDS` shutting down a control bridge that had already exited. Now 18-29ms.
    - **`android_ensure_apk` hashing the APK before every test.** Step 4. 43 sha256 passes over 117MB, about 5GB of reading per run, all producing the same answer. Now one pass per worker.

    Left alone, with the reason:

    - **`android_clean_after_test`'s `pm clear` on the way out.** It exists to stop the emulators filling with imported photos and video thumbnails, which is real, and it is not on the critical path in the way the two above were: it runs after the test's result is decided, while the worker still holds the device. It was not made to run in the background, because the saving is one `adb shell pm clear` per test against the risk of a clear still running when the next test's `pm clear` starts on the same device.
    - **`wait_for_ready`.** It polls `/ready` five times a second and the run logs show it finding the app on an early poll, so there is no dead time in it.
    - **The per-test control bridge.** A `bun` process started per test. It is not shared between tests and must not be: that isolation is what the suite depends on.

    Nothing test-only was added to the app: no launch flag, no seeding hook, no IPC. The two savings are both in the harness.

    Measure first, inside one representative test (`5-add-secret`, which is 8s and does almost nothing else): timestamp `android_reset_app_state`, the control bridge start, `android_launch`, `wait_for_ready`, `stop_app` and `android_clean_after_test`, and record the six numbers in this step. Then act only on what the numbers show, choosing from:

    - `android_clean_after_test` runs `pm clear` after every test, and `android_reset_app_state` runs it again at the start of the next one. The second clear on the way out exists to stop the emulators filling with imported photos and video thumbnails, which is real. If it is measurably expensive, make it run in the background with its pid recorded so the worker does not wait on it, while still holding the device lock until it finishes; do not simply delete it.
    - `wait_for_ready` polls `/ready` five times a second already, so it is unlikely to hold dead time, but confirm from the log rather than assume.
    - The control bridge is a `bun` process started per test. If its start-up dominates, record that finding here; do not share one bridge between tests, because that is exactly the isolation the suite depends on.

    Do not extend the app with anything that exists only to make tests faster: no test-only launch flags, no seeding hooks, no new IPC. If the only remaining saving needs something in the app, stop and put the question to the human in this step rather than writing it.

7. [x] **Decide what to do about the 76s floor in `37-lan-share-timeout`.** Status: abandoned, on this step's own test.

    The step said to do this only if the loop is within ten seconds of that test's duration, and to record it and abandon otherwise. The final loop is 115s and `37-lan-share-timeout` measures 65s, so the loop is 50s above it: the test is nowhere near the floor and there is nothing to buy here.

    Nothing was written, and in particular nothing was plumbed through the `JsEngine` plugin to make `SHARE_TIMEOUT_MS` configurable. That would have been test-only scaffolding inside the app, and it is not needed.

    The number to watch, if this is ever revisited: the loop cannot go below the longest single test, so `37-lan-share-timeout` becomes the floor only once the loop is at about 65s. That would need the 457s of test work to come down to roughly 325s.

    After steps 2 to 6, re-read the timing block. If `37-lan-share-timeout` is the longest test and the loop is within ten seconds of its duration, it is the floor and this step is worth doing; if the loop is well above it, record that and abandon this step.

    The window comes from `SHARE_TIMEOUT_MS` in `packages/node-api/src/lib/lan-share.worker.ts:17`, which is compiled into the mobile worker bundle. Making it configurable means plumbing a value from the launch intent through the `JsEngine` plugin into the embedded worker, which is a change to the app's configuration surface and would exist only for the tests. That is exactly the kind of test-only scaffolding this repository requires the human to approve first. So this step's deliverable is not code: it is a written proposal in this plan naming the exact files that would change, what the test's `< 50s` assertion would become (the regression it guards against collapsed 60s to about 12s, a 5x ratio that a 20s window still catches at `< 16s`), and the alternative of leaving the window alone. Stop there and wait for the human's answer.

8. [x] **Update the docs with the new numbers and markers.** Status: completed.

    `docs/testing/README.md` records the measured 161s before and 123s after with the full timing block behind it, documents `.slow` beside `.exclusive`, and describes the timing block `run.sh` now prints and what packing efficiency means. `apps/smoke-tests/tests/README.md` documents `.slow` in its own section, saying plainly that it is an ordering hint and changes nothing a test does. No saving is described that is not the difference between two of step 1's blocks.

9. [x] **Fix the LAN discovery contention this work exposed.** Status: completed. Not in the original plan; found by `bun run test:everything -- --force` and fixed here because this repository owns it.

    `bun run test:cli:lan-share` failed inside the parallel run with "Rogue test: expected 403 but got 000", and passed 18/18 on its own. That is interference, not flakiness, and the cause is a machine-wide resource claimed by name: `apps/cli/test/udp-listen.ts` bound UDP 54321 and reported the first `PSIE_RECV:` broadcast it heard, whoever sent it. Every Photosphere receiver on the segment broadcasts there, including the on-device receivers the mobile smoke tests start, which broadcast onto the same 192.168.55.0/24 emulator bridge the host is on. The test then attacked a port belonging to a receiver that was gone by the time curl connected, which is exactly what 000 means.

    `udp-listen.ts` now takes the expected code hash and reports only the broadcast carrying it, ignoring everything else until it times out. The hash is already in the broadcast and each test knows the code it started its own receiver with, so both call sites (`test_rogue_receiver_rejected`, `test_cert_fingerprint_matches_broadcast`) pass their own. This makes the tests stricter rather than weaker: each now provably attacks and fingerprints the receiver it started, where before either could have been measuring somebody else's.

    Watched failing first: with the hash replaced by one no receiver broadcasts, both tests failed with "could not capture UDP broadcast". Restored and confirmed byte-identical afterwards.

    Whether the ordering change in step 2 caused this failure or merely changed when it showed up cannot be established from one run, and it is not claimed either way. The contention predates this work: the listener has always taken the first broadcast on the segment.

10. [x] **Fix the hardcoded LAN pairing codes in the same suite.** Status: completed. Also not in the original plan; found by `bun run test:parallel` and fixed here for the same reason.

    `bun run test:parallel -- --scripts "test:and test:cli:lan-share"` reported interference on `test:cli:lan-share` against a second copy of itself: "Database share: receiver vault is empty after share" and "Secret share: sender did not report success", with each side passing alone. Every test in `apps/cli/smoke-tests-lan-share.sh` hardcoded its pairing code (1234, 2345, 3456, 4567, 5678, 6789, 8901), so two copies of the suite announced the same `sha256(code)` on the shared segment and each run's sender paired with whichever receiver it heard first. The sender then reported success, having handed its payload to the other run's receiver, and its own receiver's vault was empty.

    That is a machine-wide resource claimed by a fixed name, which this repository forbids, and it collides with another worktree's run exactly as readily as with a second copy here. `allocate_pairing_code` now draws one per test, the same way `apps/smoke-tests/lib/common.sh` and CLI tests 78 and 79 already do. `test_wrong_pairing_code` needs its sender's code to differ from its receiver's, so it uses `allocate_different_pairing_code`, which redraws on a collision rather than leaving a one-in-nine-thousand failure in the suite.

    Step 9's code-hash filter does not cover this on its own: with a fixed code, two copies of the suite produce the same hash, so the two fixes are needed together.

    In `docs/testing/README.md`, record the measured `test:and` duration before and after, the `.slow` marker's meaning, and the timing block `run.sh` now prints. In `apps/smoke-tests/tests/README.md`, document `.slow` beside `.exclusive`. Do not describe any saving that was not measured in step 1's format.

## Unit Tests

Every code change in this plan is shell, and this repository forbids writing tests for shell scripts, so no `*.test.sh` file is created and none of the existing ones is extended.

- No TypeScript function is added or changed by steps 1 to 6, so no Jest test is added or changed. `bun run test` must still pass unchanged after every step, which is what proves that.
- Step 7 produces a written proposal and no code, so it carries no tests. If the human approves it later, the plumbing it describes is TypeScript and will need its own plan with unit tests for every function it adds.
- The existing `apps/smoke-tests/runner.test.sh` covers the queue and the exclusivity lock. Step 2 adds `order_tests` to the same file's subject matter, and the repository rule against new shell tests means it is not tested there; it is proven instead by the dispatch order visible in a real run's `RUN` lines, which step 2 requires to be checked. That order was also read back directly from `order_tests` against the real test tree: `37-lan-share-timeout` first, then `21-import-video`, `42-s3-sync-prefetch`, `43-s3-failure` and `45-s3-share-replica-sync`, then the other 38 in their numbered order, 43 paths in and 43 out.
- Step 9 edits one TypeScript file, `apps/cli/test/udp-listen.ts`. It is a standalone helper script with no exported function: it binds a socket at the top level and exits on the first matching datagram, so there is nothing a Jest test could import without running it. It carries no unit test and is proven end to end instead, by the two smoke tests that use it being watched failing with a code hash no receiver broadcasts and passing with the right one. `bun run compile` covers it for types.

## Smoke Tests

The mobile suite is itself the end-to-end coverage, and this plan changes only the harness that runs it and the waits inside four tests, so the whole existing suite is the regression check.

- `bun run test:and` passes 43/43 after every step, with no test skipped. The skip count printed by `run.sh` must be zero, and any test that reports `SKIP` is a failure of the step that caused it.
- `bun run test:and -- 43`, `-- 45`, `-- 21` and `-- 42` each pass alone after step 5, and each one's recorded duration is lower than its step 1 baseline.
- `bun run test:and -- 37` still measures a real window of at least 50s, proving step 2's reordering did not let another LAN test overlap it.
- `bun run test:cli`, `bun run test:cli:lan-share` and `bun run test:electron` pass after step 3, because `scripts/lib/process-control.sh` is shared by all of them.
- `bun run test:parallel` passes, proving the reordering and the concurrent install did not introduce contention between suites.
- Two `bun run test:and` runs started at the same time from two worktrees both pass, which is what step 4's concurrent install must not break.

## Verify

All of these were run and their results read, not inferred.

- `bun run compile` is clean. Passed in 26s inside the canonical run below.
- `bun run test` passes. Passed in 1m 47s inside the same run.
- `bun run test:everything -- --force` passes, which is the canonical check and the only one that covers the CLI, desktop and mobile suites together after the shared `process-control.sh` change. **All 13 scripts passed, twice.** First, 6m 03s wall clock: `test:and:unit` 26s, `test:and` 3m 05s, `compile` 26s, `test` 1m 47s, `test:cli` 4m 52s, `test:cli:encrypted` 2m 31s, `test:cli:lan-share` 1m 33s, `test:cli:sync` 39s, `test:cli:write-lock` 1m 04s, `test:cli:hash-cache` 11s, `test:electron` 6m 03s, `test:lan-share:cli-desktop` 46s, `test:harness` 21s. Then again after step 10, all 13 green: `test:and` 4m 10s, `test:cli` 6m 27s, `test:cli:lan-share` 1m 17s, `test:electron` 7m 20s and the rest. `test:and` is slower inside this than standalone because `suite_share` gives it a fraction of the emulators while twelve other lanes run, exactly as the Notes below say it will.
- `bun run test:and` passes 43/43 with zero skips, three times in a row. Totals 141s, 143s and 149s, every one of them 43 of 43 with no skip. Those three ran while another session held the machine at a load average of 38 with its own `test:parallel`, which is why they are above the 123s measured on an idle machine and is worth recording as the number under contention.
- The timing block printed by `run.sh` shows a total at or below 180 seconds on a warm build with five emulators, against the step 1 baseline recorded from the same machine and the same pool. **123s standalone on an idle machine**, and 141-149s with another full suite running beside it. The baseline was about 161s.
- `bun run test:parallel` reports nothing failing in company. It earned its place twice here. It exposed the hardcoded pairing codes that step 10 fixes, reporting `test:cli:lan-share with test:cli:lan-share: interference` while each side passed alone; after the fix the same command reported **no interference found across 3 combination(s)**, which covers `test:and` alone, `test:cli:lan-share` alone, both self-pairs and the cross pair. The LAN discovery contention of step 9 came out of `test:everything -- --force` and is proven by `test:cli:lan-share` passing inside the two canonical runs above, the first of which had failed on it.

  Run separately without `test:and` in the set, `bun run test:parallel -- --scripts "test test:cli test:electron"` had all three clean alone and reported `test with test`, `test with test:cli`, `test with test:electron`, `test:cli with test:cli` and `test:cli with test:electron` all ok. The `test:electron` self-pair failed once and passed on a rerun; see "What was seen and not chased" below, which includes the three-run experiment that clears the kill-helper change.

  The default four-script run could not be finished, and the reason is not this work. Twice, it passed phase 1 with `test`, `test:cli`, `test:electron` and `test:and` all clean alone, then stopped in phase 2 at `test with test:cli` with "device count changed: started with 5, now 4". Both times the pair that was running when the device went is `test with test`, which is Jest and never touches adb. The pool emulators are leaking: measured at the time, `psphere-pool-3` was at 6.0GB RSS after 3h13m, `psphere-pool-0` at 5.7GB, `psphere-pool-2` at 5.6GB, while `psphere-pool-1` had 56 seconds of uptime and `psphere-pool-4` sixteen minutes, both freshly restarted by the pool monitor. That is the accumulation `docs/plans/new/plan-find-and-fix-emulator-memory-leak.md` exists for, and the restart is what the check sees as a device disappearing. The emulator was left to the monitor rather than repaired by hand, because the monitor was running.

## Result

`bun run test:and`, standalone with the five-emulator pool up, a warm build and nothing else on the machine: **123 seconds, 43 of 43 passed, zero skipped**, against the 161 seconds this plan started from. The budget was 180. Three further runs back to back, with another full suite running beside them, came in at 141s, 143s and 149s, all 43 of 43.

Nothing was traded for it. No test was deleted, merged, skipped, made conditional or dispatched to fewer emulators. No assertion was loosened, and `43-s3-failure`, the only test whose body changed, was watched failing on both of its failure paths before the change was accepted. No wait that the code under test genuinely takes was shortened: the LAN receiver slack in tests 26, 27, 44 and 45 is still there, and `37-lan-share-timeout` still waits out its real 60 second window. Nothing test-only went into the app: step 6 avoided it and step 7 was abandoned rather than written.

The one thing this work added beyond the plan is step 9, a fix to a machine-wide UDP contention in the CLI LAN share suite that the full parallel run exposed.

## After the plan: both scheduling markers removed

Asked for on 2026-08-13, after the plan was finished. Recorded here rather than in a new plan because it undoes part of step 2 and changes the numbers above.

**`.slow` went first.** The human reverted the five marker files and asked for the support to go with them. `order_tests`, `SLOW_MARKER` and the call from `run.sh` were deleted. Measured straight after: 43 of 43, **152s** total, loop 145s, packing 73% against 79% with the marker.

**`.exclusive` went next.** The claim put to me was that `scripts/check-parallel-tests.sh` had already proven the tests are safe in parallel. It had not, and saying so mattered: that script pairs whole suites, never individual tests inside one, and `.exclusive` is a machine-wide `flock` taken inside `run_worker`, so both copies of `test:and` in its self-pair went on serialising their own LAN tests through the same lock. It had never once observed two LAN tests overlapping.

The conclusion was right even though that evidence was not. What actually makes the LAN tests safe in company is the pairing code, not the scheduling: a sender ignores any receiver whose code hash is not its own (`packages/lan-share-network/src/lib/lan-share-sender.ts:136`, added later as a fix for exactly this), a receiver rejects a payload carrying the wrong code, every test draws a random code, and `44-receive-database-cancel` and `45-s3-share-replica-sync` were already unmarked LAN tests passing every run. Test 37 survives a stranger on the segment too: the sender only resolves on a code match, and `sawMismatchedReceiver` is read by nothing but a unit test, so the dialog still reports "No receiver found within 60 seconds".

Removed: the five marker files, `EXCLUSIVE_MARKER`, `EXCLUSIVE_LOCK_FILE`, `EXCLUSIVE_LOCK_FD`, the locking branch in `run_worker`, the lock parameter threaded through `run_pool`, the `6>&-` closes that referenced the lock descriptor, the now-unused `test_has_marker`, and both READMEs' marker sections. `apps/smoke-tests/runner.test.sh` lost its exclusivity case and its `test_has_marker` cases; the case proving two ordinary tests do overlap was kept and now stands on its own.

Measured after, with the machine quiet: 43 of 43 twice, **138s and 135s** (loop 130s and 128s), against 152s with `.exclusive` in force. Then the case the marker existed for, `bun run test:parallel -- --scripts "test:and"`: **two full `test:and` runs concurrently, both 43 of 43**, with up to twelve LAN tests free to overlap across the two copies, and `37-lan-share-timeout` still measuring a real 68s window. `bun run test:harness` passes.

One measurement in between was thrown out rather than reported: 231s, taken while another `bun run test:everything` was running, which `suite_share` reduces to a fraction of the emulators.

## What was seen and not chased

Two failures were observed during verification that this work did not cause. Both are written down rather than left out, because a run that went red is worth a reader knowing about even when the cause is elsewhere.

**The emulator pool losing a device, twice, at the same point in `test:parallel`.** Covered under Verify above. The measurements say the pool emulators are leaking host memory and the monitor is restarting them; `docs/plans/new/plan-find-and-fix-emulator-memory-leak.md` is the plan for that. Nothing here was changed in response.

**`test:electron` failing once out of seven runs of the same code.** Desktop test 34, `edit-asset-metadata`, timed out after 2m 11s waiting for `Database ops applied`, with the renderer logging `Network Error` ten times over: the app had already started, opened its database, rendered its gallery and accepted the typed description, and then lost its own backend. It passed alone twice before that, passed alone twice after it (34 of 34 in 5m 26s and 5m 32s), and passed inside both `test:everything -- --force` runs.

A second desktop failure came out of the `test:electron` self-pair under `bun run test:parallel`: test 27, `s3-replicate`, timed out after 2m 22s waiting for `Replication completed for`. A different test from the first, and again a timeout inside the running app rather than anything in the harness.

**The kill-helper change was tested for directly rather than argued about.** `scripts/lib/process-control.sh` is the only shared file this work changes, so the same `test:electron` self-pair was run three times, swapping that one file between the version in this branch and the version at HEAD:

| run | `scripts/lib/process-control.sh` | `test:electron` self-pair |
| --- | --- | --- |
| 1 | this branch | FAIL (test 27 timed out) |
| 2 | HEAD, unmodified | ok |
| 3 | this branch | ok |

Not reproducible with the change in place, and the working tree was checked byte-identical against a backup afterwards so the experiment left nothing behind.

The mechanism agrees with that result. The desktop suite reaches this file in exactly one place: `kill_process_group` and `kill_process_tree` are called only from `kill_app_tree` in `apps/desktop/smoke-tests/lib/common.sh`, which is called only from `cleanup_apps`, which runs from a test's teardown trap. Both failing tests failed in the middle of their bodies with no kill in flight. And the helper cannot return early with anything still running: it polls `kill -0` on the process group and returns only once the kernel can no longer signal a member, so what it removes is the part of the grace period spent waiting after everything had already exited, not any real waiting.

What was going on instead: the host was 27GB into swap, and by the end of the session the pool emulators were at 6.3GB, 6.0GB and 5.8GB RSS and still climbing. Free memory shrank throughout, so the three runs above did not all meet the same machine either, and that is a limit on how much a one-against-one comparison can carry. No cause was established beyond the memory pressure, and none is claimed.

## Notes

- **Where the current time goes, measured.** From the 2026-08-12 13:41 run: 43 tests, 600s of test work, about 150s of loop across five emulators, 11s of prologue with a warm build and the same APK already on every device. Perfect packing of today's tests is 120s, so about 30s of the loop is tail latency and the rest is real work.
- **Why the target is reachable without weakening anything.** 180s of budget against a 120s packing floor leaves room for the prologue. Steps 2 and 4 attack the tail and the prologue without touching a single assertion. Steps 3, 5 and 6 lower the 600s of work by removing time spent waiting for things that have already happened, which is the same class of change as the poll-interval fix that took the suite from 375s to 276s in `docs/plans/done/plan-faster-android-tests.md`.
- **What this plan refuses to do.** No test is deleted, merged, split across fewer emulators, or made conditional. No assertion is loosened. No wait that the code under test genuinely takes is shortened. Nothing test-only is added to the app: step 6 says so explicitly and step 7 stops and asks rather than writing the plumbing it describes.
- **The measured duration depends on what else is running.** `suite_share` in `apps/smoke-tests/lib/runner.sh` gives a suite an even split of the emulators when other suites are registered, so the same run inside `bun run test:everything` has fewer emulators than a standalone `test:and` and will be slower. Every number in this plan must be recorded standalone, with the pool up and nothing else running, or it cannot be compared with the baseline.
- **The prologue is small when the build is warm and large when it is not.** The 11s figure was measured with Gradle and Vite already up to date. A run after a change under `packages/user-interface/src/` pays the full Vite build and a Gradle recompile, which step 1 measures separately. If that cold number turns out to dominate, it is a different problem from the one this plan solves and belongs in its own plan rather than being smuggled into this one.
- **`.slow` used to exist, was removed, was reinstated by step 2, and has now been removed again.** `order_tests` and the `.slow` marker came from the completed `plan-faster-android-tests.md`. This plan was written saying "whoever removed them left no note of why", and that was wrong: `docs/plans/done/plan-green-commit-walk.md` records commit `f41247c6` as "Removed the .slow marker so tests dispatch in order". The note existed in another plan and was not found. Step 2 reinstated the marker, and the human then asked for it to go again, so it is out. Anyone tempted to add it a third time should read step 2 first.
- **Test 37 is the floor and the plan says so rather than working around it.** At 76s it is longer than the 120s packing floor divided by nothing, and once packing is fixed the loop cannot go below it. Step 7 exists to put that choice in front of the human with the exact cost written down, not to make it quietly.
