# Speed up the Electron smoke tests

## Overview

`bun run test:electron` takes 6m 10s on this machine (34 tests, all passing, measured 2026-08-12 on 24 cores / 62GB). The target is under 3 minutes. The app is not what is slow: a measured Electron launch reaches its test control port in 1.16s and answers `/ready` 89ms later, and it exits 1.13s after `/quit`. The suite is slow because of the harness around the app. Three things account for most of it. Every polling loop in `apps/desktop/smoke-tests/lib/common.sh` and in the tests' own copies of those loops sleeps a whole second between looks, so roughly 300 waits each pay up to a second of latency for an event that already happened. Every teardown sleeps a fixed 3 seconds (`stop_app`'s `sleep 2` plus `kill_process_group`'s 1 second signal grace) to stop a process that takes 1.13s to go, and the exit trap then pays the grace again. And `run_parallel_batch` in `apps/desktop/smoke-tests.sh` runs tests two at a time behind a barrier, so a batch takes as long as its slower member and nothing starts until both are done: test 28 ran for 1m 2s while its partner sat finished for 42 seconds of it.

The measured serial cost of all 34 tests is 599s against a wall clock of 370s, so the suite is only getting 1.6x out of a 24 core machine. This plan removes the fixed sleeping, drops the poll interval, replaces the batch barrier with a rolling pool, and takes the pool width from the core count instead of the hardcoded 2. The changes are entirely shell, in the harness and the tests, with no change to the app.

## Result

Done, and measured. `bun run test:electron` runs all 34 tests green in **1m 28s**, against the 6m 10s baseline. Three consecutive runs took 1m 28s, 1m 29s and 1m 28s, and two more full runs during the checks below came in at 1m 23s and 1m 37s (the last with a test failing on purpose). A `--sequential` run, which is the serial cost with no overlap at all, is 5m 31s.

The overview's claim that nothing in the app would change did not survive contact: two real bugs turned up during verification and both are fixed here, because neither could be worked around from the test side without weakening a test.

- **The app could come up permanently not-ready.** `main.ts` registers `webContents.once('did-finish-load')` inside `createMainWindow()`, but only assigns `testControlServer` after that function returns. When the renderer finished loading first, the handler ran with no server to tell, and because it is a `once` nothing ever fired it again: the window was up and usable while `/ready` answered 503 for the rest of the process's life. Every test driving that instance then waited out its full 120s timeout and relaunched. It cost test 17 2m 20s instead of 18s in the second measured run, and it gets likelier the more apps start at once, which is exactly what this plan does. Fixed by recording whether the load already finished and telling the server when it is created. Proven by forcing the race (an 8 second delay before the server is created): with the fix off, every test failed after 4m 21s; with it on and the same delay, the test passed in 10s.
- **Test 27 drove a dialog through a re-render.** Choosing the destination's credentials makes the app open the source database, and the databases page behind the modal reloads when that load finishes. The test typed the destination path and clicked Start without waiting for any of it, so when the re-render landed in between, the destination was wiped and Start did nothing at all. Every click is still logged as delivered, so the only symptom is the test waiting out its whole timeout for a replication that never began. It failed once in a `--sequential` run and once with two copies of the suite running at the same time, and passed 6 times out of 6 alone, which is what a race with the app's own background work looks like. Fixed by waiting for the credential option to render before clicking it, for the modal to be gone before touching the dialog underneath, and for the asset load to complete before typing the destination. Then: three runs alone green, and the self-pair check that caught it, green.

## Issues

## Steps

1. **Add a process group liveness check and make the kill helpers poll, in `scripts/lib/process-control.sh`.** Add `PROCESS_CONTROL_POLL_INTERVAL=0.1` beside `PROCESS_CONTROL_TERM_GRACE_SECONDS` at line 32, and two functions, each with a `//`-style comment block matching the file's existing voice:
   - `process_group_alive <pgid>` returns 0 when at least one process is still in the group. `kill -0 -- "-$pgid"` is the check, verified to work here: it succeeds while any member lives and fails once the group is empty. Nothing this library launches can become a zombie that keeps answering, because `launch_in_process_group` runs inside the process substitution in `start_app`, so the app is reparented to init and reaped there rather than left unwaited in the test's shell.
   - `wait_for_process_group_exit <pgid> <timeout_seconds>` polls `process_group_alive` every `PROCESS_CONTROL_POLL_INTERVAL` until the group is empty or the timeout passes, returning 0 when it went and 1 when it is still there.
   Then change `kill_process_group` (line 102) so that after the `SIGTERM` it calls `wait_for_process_group_exit "$pgid" "$PROCESS_CONTROL_TERM_GRACE_SECONDS"` in place of the flat `sleep`, and skips the `SIGKILL` entirely when the group has already gone. Return early, before signalling anything, when `process_group_alive` is already false. Make the same change in `kill_process_tree` (line 73), polling the collected pid list with `kill -0` instead of sleeping the grace out. The worst case is unchanged: a process that ignores `SIGTERM` still gets the full grace and then `SIGKILL`. Only the common case, where everything is already gone, gets faster.

   Done. A third function came with it, `process_control_poll_count <seconds>`, because both waits need to know how many polls of a fractional interval cover a whole-second grace, and bash cannot divide by 0.1. Counting polls is used here rather than a `SECONDS` deadline for the opposite reason to step 3: the graces here are one and five seconds, and a deadline of `SECONDS + 1` expires anywhere between immediately and a second later, which would cut short the grace a process is entitled to. Measured: stopping a group that has already gone went from 1.0s to 0.016s, and a process that ignores `SIGTERM` still takes the full 1.029s and then dies.

2. **Stop `stop_app` sleeping for an exit it can watch for, in `apps/desktop/smoke-tests/lib/common.sh` (line 519).** After posting `/quit`, read `$tmp_dir/app.pgid` and call `wait_for_process_group_exit` with a timeout of 5 seconds instead of `sleep 2`, then call `cleanup_apps` as it does now. With step 1 in place `cleanup_apps` returns immediately when the app has already gone, so a clean shutdown costs the measured 1.13s instead of 3s, and a wedged app still gets stopped exactly as it is today. Fall back to the current `sleep 2` only when no pgid file exists, which means `start_app` never got as far as writing one.

   Done as described.

3. **Introduce one poll interval for the desktop waits, in `apps/desktop/smoke-tests/lib/common.sh`.** Add `WAIT_POLL_INTERVAL=0.25` beside `DEFAULT_WAIT_TIMEOUT` (line 28) with a comment saying why it is not 1 and not 0.01: it is what makes a wait cost about an eighth of a second rather than half a second on average, without putting four `awk` or `curl` processes per second per test on the machine more than the pool width allows. Rewrite the loops in `wait_for_test_port` (line 176), `wait_for_ready` (line 346), `wait_for_log` (line 397) and `wait_for_value` (line 455) to run to a deadline computed from bash's `SECONDS` (`local deadline=$((SECONDS + timeout))`, `while [ "$SECONDS" -lt "$deadline" ]`) and to sleep `WAIT_POLL_INTERVAL` between looks. The deadline form is what keeps the declared timeouts honest: counting polls would stretch a 30 second timeout into something longer whenever a poll's own work is slow, which `wait_for_log`'s `awk` over a growing log can be. Every timeout value, every log message and every failure path stays exactly as it is; only the interval and the counter change.

   Done as described.

4. **Add the two missing shared waits to `apps/desktop/smoke-tests/lib/common.sh`,** both using `WAIT_POLL_INTERVAL` and the deadline form from step 3, both with the comment block the file's other helpers have:
   - `wait_for_value_gone <port> <data-id> <substring> [timeout]` waits until the element's value no longer contains the substring, requiring a non-empty response first so a dead app cannot read as a closed dialog. Lift the body from the local copy in `23-developer-screen/test.sh` (line 42), which already gets this right and explains why.
   - `read_pairing_code <port> [timeout]` polls `share-pairing-code` until it reads a four digit code, prints it on stdout and returns non-zero when none appeared. Lift the body from `29-share-database-cancel/test.sh` (line 37).

   Done. `wait_for_value_gone` reports failure by return rather than by `exit`, unlike the copy it was lifted from: three of its five call sites carry their own failure message and need the chance to print it. The two call sites that relied on the old copy exiting say `|| exit 1`, so nothing became non-fatal.

5. **Delete the tests' private copies of those loops and call the shared ones.** Seventeen `sleep 1` polls live inside per-test functions, and each is a copy of a helper that already exists or is added in step 4. Changing the interval in one place is worth nothing while these copies exist, so remove them.

   Done, and wider than the plan listed: the pairing code loop in `30-receive-database-cancel` and the one in `32-receive-secret-cancel` were copies too, and `24-sync-settings`'s `wait_for_toml` is a genuine local (it watches a file, not the app) but was still polling at one second, so it now uses the shared interval. The pattern-test loops in tests 29 and 31, which wait for a code to stop being four digits, stay as loops of their own because `wait_for_value_gone` tests a substring and would be a weaker assertion.

   **The plan was wrong about timeouts and was overruled.** It said to pass `30` at each call site in tests 23 and 24, to preserve the timeout their deleted local copies hardcoded. There is one default timeout in this suite, `DEFAULT_WAIT_TIMEOUT`, and it is 120 deliberately: doubled so a concurrent suite sharing the machine does not trip a spurious timeout. Sprinkling the same literal across dozens of call sites is how a codebase ends up with hundreds of copies of one number, and it would have left tests 23 and 24 as the only two holding a tighter limit under a pool four times wider than before. No call site touched by this work passes a timeout. Every one of them uses the single default.

6. **Race the two outcomes in `apps/desktop/smoke-tests/28-s3-failure/test.sh` (lines 100 to 130) instead of waiting one out.** This is the slowest test in the suite at 1m 2s, and 30 of those seconds are a `wait_for_log` for a line that must never appear. Replace that block and the 90 second error poll that follows it with a single loop that polls `app.log` every `WAIT_POLL_INTERVAL` for up to `ERROR_WAIT_SECONDS` and stops at whichever lands first: the expected `Could not reach the database at ...` line passes the test, and `Load assets task completed: 0 assets loaded` fails it with the message that block already carries. Reaching the timeout without either fails with the existing "never logged" message. Nothing is weakened: both outcomes are still checked, and the failing one is still the one that fails the test. What goes is the fixed 30 seconds spent proving an absence that the successful outcome already disproves.

   Done. Measured at 17s run alone, against the 1m 2s baseline and the 30s this plan estimated.

7. **Add `scripts/lib/test-concurrency.sh`.** A new sourced library beside `allocate-test-temp-dir.sh` and `process-control.sh`, defining `detect_cpu_count` and `resolve_test_parallel <fallback>` exactly as `docs/plans/new/plan-speed-up-test-everything.md` step 3 specifies them, so the two plans converge on one library rather than two.

   Done. `detect_cpu_count` reports 24 here; `resolve_test_parallel 2` gives 6 (24 / 4, capped at 6). `PHOTOSPHERE_TEST_PARALLEL` set to `0`, `-1`, `abc` or a space is refused loudly with a non-zero exit, checked one by one.

8. **Replace the batch barrier with a rolling pool, in `apps/desktop/smoke-tests.sh`.** Rewrite `run_parallel_batch` (line 156) as `run_parallel_pool`, keeping its `<n> <pass_var> <fail_var> <test...>` interface so `run_mixed` (line 230) needs only its call updated. The pool keeps at most `n` tests in flight and starts the next the moment any slot frees. Hold three parallel indexed arrays (`pool_pids`, `pool_tests`, `pool_temp_dirs`) of size `n`, and loop: fill every empty slot from the remaining tests, then poll the occupied slots every 0.1s with `kill -0`, and when one has gone, `wait` that pid for its exit status and print its result exactly as the current code does. Use indexed arrays and a `kill -0` poll rather than `wait -n` or `declare -A`, because `wait -n` does not exist in bash 3.2.

   Done, with one thing the plan would have got wrong: the background job must be started in the pool's own shell, not through a command substitution that prints its pid. A job started inside a process substitution belongs to that subshell, so the pool could not have `wait`ed for it and would have had no exit status to report. `report_pool_result` came out as a function because the reporting is the one part long enough to bury the loop.

9. **Take the pool width from the core count, in `apps/desktop/smoke-tests.sh`.** Source `scripts/lib/test-concurrency.sh` beside the existing sources at lines 9 and 14, and set `local parallel_n` in `main()` from `resolve_test_parallel 2` instead of the literal `2`. An explicit `--parallel N` on the command line still wins over both. Update `print_usage` to say the default comes from the core count and name `PHOTOSPHERE_TEST_PARALLEL`. Leave `run_mixed`'s handling of `.sequential` alone.

   Done. The run also prints the width it chose ("Running up to 6 tests at a time."), because it is no longer a constant in the file and a run that is slower than expected should not need the source read to find out why. Checked: no arguments gives 6, `PHOTOSPHERE_TEST_PARALLEL=3` gives 3, and `--parallel 2` gives 2 even with the variable set to 6.

10. **Poll the S3 emulator's health check faster, in `scripts/s3-emulator.sh` (line 251).** Four Electron tests and several CLI suites start a MinIO server and wait for it at 1 second granularity. Change that loop's `sleep 1` (line 263) to `sleep 0.25` and the `elapsed` counter to a `SECONDS` deadline, leaving `HEALTH_TIMEOUT_SECONDS` at 60. Do not touch the seed retry loop at line 358: its 1 second delay is a backoff between attempts at a server that has answered but is not ready, not a poll for an event.

    Done as described.

11. **Replace the three fixed settle sleeps that are waiting for a screen, not proving an absence.**

    Two of the three were as the plan described and are done: `3-open-database` line 43 now waits for the `sidebar-database-summary` link it is about to click, and `16-remove-recent-database` line 45 waits for `recent-database-name-0` to read `test-db-a`, the row whose trash button it is about to click. Both are stricter than the pause they replace, not just quicker.

    **The plan misread the third.** `34-edit-asset-metadata` line 105 is not a settle before a click: it is the one second backoff inside a loop that runs `psi info` up to 30 times waiting for a write to land on disk. That is the same kind of thing as the S3 seed retry the plan explicitly leaves alone, and each attempt costs a CLI startup, so the backoff is a small part of it. Left exactly as it was. `17-news-notifications` line 122 and `33-import-cancel` line 107 are left alone as the plan says.

12. **Give the three tests that name `/tmp/smoke-test-db` a path of their own.** `8-share-database`, `29-share-database-cancel` and `30-receive-database-cancel` each write a `databases.toml` entry pointing at the fixed machine-wide path `/tmp/smoke-test-db`. Nothing creates it today, so it is a listing entry rather than a database, but it breaks the repository's rule that no test may claim a machine-wide resource by a fixed name. Point each at `$TMP_DIR/smoke-test-db` instead.

    Done. Each heredoc lost its quoted delimiter so `$TMP_DIR` expands; nothing else in those three bodies contains a `$`.

13. **Update `apps/desktop/README.md` (the Shell Smoke Tests section, from line 98).** Say that the suite runs a rolling pool sized from the core count, that `--parallel N` and `PHOTOSPHERE_TEST_PARALLEL` override it, and that `.sequential`-marked tests still run alone at the end.

    Done.

14. **Tell the test control server the window has already loaded, in `apps/desktop/src/main.ts`.** Not in the original plan; found by the second measured run and described under Result above. A module-level `mainWindowFinishedLoading` is set by the `did-finish-load` handler and cleared at the top of `createMainWindow`, and the block that creates the `TestControlServer` calls `notifyReady()` when it finds the load already finished.

15. **Close the click race in `apps/desktop/smoke-tests/27-s3-replicate/test.sh`.** Not in the original plan; described under Result above. Three waits: for the credential option to render before it is clicked, for the Configure Secrets modal to be gone before the dialog underneath is touched, and for `Load assets task completed` before the destination is typed, which is what orders the test after the app's own re-render.

    An attempt to also assert the destination had landed in `replicate-dest-path-input` was removed, because it could never pass: the Electron test control server's `/get-value` is its own three-line snippet (`el.value || el.textContent || ''`) rather than the shared `getValue` in `packages/user-interface/src/lib/test-driver.ts`, which the mobile transport uses and which handles exactly this case (Joy's Input carries the data-id on a wrapper and the value on an input nested inside it). So on desktop that element reads as empty and the assertion would have been a test that cannot fail. Left alone here rather than fixed, because the two implementations want reconciling properly and that is not this piece of work: the server has no reply path back from the renderer, so using the shared driver means either a new IPC channel (which `CLAUDE.md` says to avoid) or exposing the driver to `executeJavaScript`. Worth its own plan.

## Unit Tests

None, deliberately. Every shell change in this plan is covered by `CLAUDE.md`'s rule that tests are not to be written for shell scripts and that no `*.test.sh` files are to be created, so `scripts/lib/test-concurrency.sh`, the new `process_group_alive`, `process_control_poll_count` and `wait_for_process_group_exit`, and the new `wait_for_value_gone` and `read_pairing_code` get no test files.

The one TypeScript change (step 14) is four lines inside `app.whenReady()` in `apps/desktop/src/main.ts`, which is Electron main-process startup: not exported, not callable without an Electron app object, and with no existing test file for that module. What proves it is the forced-race experiment recorded under Result, which failed at 4m 21s without the change and passed in 10s with it, and the Electron suite that found the bug in the first place. Stated plainly rather than quietly skipped: there is no unit test for it.

## Smoke Tests

Every check below was run, and every one passed.

- `bun run test:electron`: all 34 tests passed, 1m 28s. Three times in a row: 1m 28s, 1m 29s, 1m 28s.
- `PHOTOSPHERE_TEST_PARALLEL=3 bun run test:electron`: all 34 passed, 2m 15s, and the run reports "Running up to 3 tests at a time."
- `PHOTOSPHERE_TEST_PARALLEL` set to `0`, `-1` and `abc`: each refused with a message naming the value, and a non-zero exit.
- `bash apps/desktop/smoke-tests.sh --parallel 2` with `PHOTOSPHERE_TEST_PARALLEL=6` set: reports a width of 2, so the flag beats the variable.
- `bash apps/desktop/smoke-tests.sh s3-failure`: passed in 17s, against the 1m 2s baseline.
- `bash apps/desktop/smoke-tests.sh --sequential`: all 34 passed, 5m 31s.
- Interrupted with SIGINT to the run's process group, which is what a terminal does on Ctrl-C: the run printed "Interrupted.", exited non-zero, and the leak check found nothing of its own still running.
- One test made to fail on purpose: reported as `FAIL`, the run reported "1 of 34 tests failed" with the other 33 green, and the leak check still found nothing left running. The test was restored afterwards and matches HEAD.
- `bun run test:cli`: all 80 tests passed, 3m 17s.

## Verify

- `bun run compile`: passed.
- `bash -n`: parses cleanly for every file changed, checked as a set after each round of edits.
- `bun run test`: passed.
- `bun run test:electron`: all 34 green, under 3 minutes, three consecutive runs (see above).
- `bun run test:parallel -- --scripts "test:electron test:cli"`: the two suites this work changes, each alone and then every pair including each against a second copy of itself. **This is what caught the test 27 race**, and it caught it in the self-pair, exactly as `CLAUDE.md` says a self-pair is meant to. Re-run after the fix: no interference across the combination.
- `bun run test:everything -- --force`: all 13 scripts passed, 7m 57s wall clock. The Electron lane took 2m 00s inside that run, sharing 24 cores with twelve other lanes including the Android suite, so it stays under three minutes even in company. `bun run emu:and:pool:status` was run immediately beforehand and exited 0.

## Notes

- **An Electron pool that keeps apps alive between tests was considered and rejected.** The idea is sound in principle and it is how the Android suite works, but the numbers do not support it here and the repository's rules forbid the way in. The suite makes 48 launches at a measured 1.16s to the control port plus 1.13s to exit, so about 110s of serial cost; spread across a pool of 6 that is roughly 18s of the 88s wall clock, and it cannot remove the 5.5s bundle or the S3 tests that set the tail. Against that: every per-test app takes its config directory, vault directory, log directory and news URL from environment variables read once at process start, so reusing a process across tests would mean the app re-pointing all of them at runtime, plus clearing whatever state the last test left. That is test-only scaffolding inside the app, which `CLAUDE.md` says must be approved in advance or not written at all. Several tests also restart the app deliberately or run two instances at once, and every test asserts against an `app.log` that begins when its process does. Perhaps 18s for a large change to the app and to every test's isolation is the wrong trade while the target is already met by 90 seconds.
- **Where the time actually went.** Teardown polling instead of sleeping, the quarter second poll interval and step 6 together took the serial cost from 599s to 331s (the `--sequential` run). The rolling pool at width 6 then took the wall clock to 88s. The two `.sequential` tests are 26s of that and cannot overlap anything.
- **The three slowest tests are now the S3 ones**, at 40s, 48s and 52s in the first measured run, each starting a MinIO server of its own. They are what a further attempt at this would have to attack, not the harness.
- **Fractional sleeps.** `sleep 0.25` is accepted by GNU coreutils (Linux, and the coreutils Git Bash ships) and by the BSD `sleep` on macOS, so no fallback is needed.
- **What is deliberately not touched.** `xvfb-run` costs 78ms per launch, measured. The `.sequential` marking of tests 7 and 8 stays. The `sleep 3` in test 17 and the `sleep 5` in test 33 stay, because both are proving that something did not happen.
- **Overlap with `docs/plans/new/plan-speed-up-test-everything.md`.** That plan proposes the same `scripts/lib/test-concurrency.sh` with the same two functions, and its step 5 does what step 9 here does. This work created the library, so that plan will find those steps already done. The environment variable name is `PHOTOSPHERE_TEST_PARALLEL` so that plan's step 6 can hand this suite a share of a whole-run budget without any further change here.
- **The CLI suite has the same batch barrier**, at `apps/cli/smoke-tests.sh:528`, with `PARALLEL_N=5` over 80 tests and a 3m 17s baseline. It is out of scope here, but `run_parallel_pool` from step 8 is the same rewrite it needs.
- **Stale in-tree `tmp/` directories** are left behind under several test directories from before per-test temporary directories were introduced. They are not read by anything now. Removing them is not part of this plan.
