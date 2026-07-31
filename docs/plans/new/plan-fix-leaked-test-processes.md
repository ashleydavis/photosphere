# Stop the test scripts leaking Electron, Xvfb and CLI processes

## Overview

Test runs leave processes behind. Right now, with no test running, this machine holds 10 orphaned Electron processes and 2 orphaned `Xvfb` servers from a run that finished nearly three hours ago, about 1.5 GB, all reparented to init. An earlier accumulation of roughly 170 such processes holding ~8.8 GB was what pushed the machine into memory pressure and triggered `systemd-oomd` to kill 354 processes in one go, taking the Android emulator pool with it. The leak has a confirmed cause: `apps/desktop/smoke-tests/lib/common.sh` gained a correct `kill_app_tree` that walks the process tree, but the 19 per-test `cleanup` functions in `apps/desktop/smoke-tests/*/test.sh` were never changed to use it and still `kill -9` the single recorded pid. That pid is the `xvfb-run` wrapper, and `xvfb-run` runs the app as a child rather than exec'ing it, so a SIGKILL to the wrapper skips its own `trap clean_up EXIT` and orphans both the Electron tree and the X server. This plan finds every such path across all the test scripts, fixes them against one shared implementation, and adds two backstops: a reaper that clears leftovers a signal-killed run could never have cleaned up, and a leak check that fails a suite which ends with more of its own processes alive than it started with, so a future regression is caught by the tests instead of by an out-of-memory kill weeks later.

## Issues

## Steps

1. **Add the shared process-control library `scripts/lib/process-control.sh`.** New file, sourced by every test script that starts a background process. It must define, each with a `#` comment block above it per the repo style: `launch_in_process_group <log_file> <argv...>` which starts a command in its own process group where `setsid` is available and plainly in the background where it is not, prints the pid it recorded and writes the process group id beside it; `process_group_of <pid>` which prints the pgid for a pid, empty when it cannot be read; `process_tree_pids <pid>` which prints the pid and every descendant deepest first, gathered before anything is killed; `kill_process_group <pgid>` which sends SIGTERM to the whole group, waits, then SIGKILL; and `kill_process_tree <pid>` which does the same over the tree walk. `kill_process_tree` must be the exact behaviour of the current `kill_app_tree` in `apps/desktop/smoke-tests/lib/common.sh` so that step 3 is a move rather than a change. The file must define functions only and must not act when sourced. `bash -n` must pass and the step is not complete until `scripts/lib/process-control.test.sh` from step 11 passes.

2. **Explain the group approach in that file's header comment.** State that the tree walk fails once a parent dies, because the children are reparented to init and `pgrep -P` then finds nothing, and that a process group survives reparenting, so killing the group is the reliable form and the tree walk is the fallback for platforms without `setsid` (macOS has no `setsid` binary). Do not restate this plan; a short paragraph.

3. **Make `apps/desktop/smoke-tests/lib/common.sh` use the library.** Source `scripts/lib/process-control.sh` near the top. Delete the local `process_tree_pids` and `kill_app_tree` definitions and keep `kill_app_tree` as a thin wrapper that prefers `kill_process_group` when a pgid was recorded for that pid and otherwise calls `kill_process_tree`, so the 19 call sites in step 5 have one name to use. Change `start_app` to launch through `launch_in_process_group` and to write the pgid to `$tmp_dir/app.pgid` next to the existing `$tmp_dir/app.pid`. Every existing behaviour of `start_app` must be unchanged: the same environment variables, the same `--no-sandbox --disable-gpu -geometry` arguments, the same `xvfb-run -a` wrapper decision, the same `app.log` redirection, and the same `wait_for_test_port` guard. `bash -n` must pass and `bun run test:electron` must pass before this step is done.

4. **Add `cleanup_apps` to `apps/desktop/smoke-tests/lib/common.sh`.** It takes any number of tmp directories and, for each, stops whatever that directory's `app.pid` and `app.pgid` describe, tolerating a missing file, a dead pid and a directory that was never used. This is the single function every per-test `cleanup` will call, so no test needs to know how a process is stopped.

5. **Replace the hand-rolled cleanup in all 19 desktop tests.** In each of `apps/desktop/smoke-tests/1-load-fixture/test.sh`, `2-create-database`, `5-add-secret`, `6-add-database-entry`, `7-share-secret`, `8-share-database`, `9-view-secret`, `10-view-database`, `11-edit-encryption-key`, `12-edit-api-key`, `13-edit-s3-credentials`, `14-rename-secret`, `15-duplicate-name`, `16-remove-recent-database`, `17-news-notifications`, `17-replicate-database`, `22-edit-database-origin`, `23-developer-screen` and `24-sync-settings`, replace the body of `cleanup` with a single `cleanup_apps` call naming that test's tmp directories. `7-share-secret` and `8-share-database` pass both `$TMP_DIR/sender` and `$TMP_DIR/receiver`. Keep each test's `trap cleanup EXIT` exactly as it is. Change nothing else in these files. `bun run test:electron` must pass before this step is done.

6. **Give `apps/smoke-tests/lib/common.sh` the same treatment.** Source `scripts/lib/process-control.sh`, launch the `bun "$LIB_DIR/control-bridge-main.ts"` bridge through `launch_in_process_group`, record `$tmp_dir/bridge.pgid`, and change the pid-based kill inside `stop_app` to use the library rather than `kill` then `kill -9` on the recorded pid. `bun` starts the bridge in a child process, so the current kill can orphan it exactly as the desktop one did. Add the missing `trap cleanup EXIT` to `apps/smoke-tests/tests/28-host-emulator-comms/test.sh`, the only one of the 37 mobile tests without one. `bun run test:and` must pass before this step is done.

7. **Fix the CLI suites.** In `apps/cli/smoke-tests.sh`, `cleanup_and_show_summary` (the `EXIT` trap) only prints a summary and kills nothing, and there is no `TERM` trap at all, so a run killed by the parallel runner's timeout leaves its batch subshells and every CLI process they started alive. Add a `TERM` trap that routes to the same handler as `INT`, and make the exit path kill the batch subshells it spawned by process group. In `apps/cli/smoke-tests-lan-share.sh` delete the local `kill_tree` and use `kill_process_tree` from the library, keeping `kill_proc` and `test_cleanup` as they are. In `apps/cli/hash-cache-smoke-test.sh` add an `EXIT`/`INT`/`TERM` trap that stops the backgrounded writer, which today has no trap of any kind. `bun run test:cli` and `bash ./apps/cli/hash-cache-smoke-test.sh` must pass before this step is done.

8. **Use the library in `scripts/story-player.sh`.** Delete the local `collect_descendants`/`kill_capture_tree` implementation and call `kill_process_tree`. Its existing `EXIT`/`INT`/`TERM` traps stay. Do not change what the story player does or how it captures screenshots.

9. **Add the reaper `scripts/reap-test-processes.sh`.** No trap can run when a process is SIGKILLed, which is exactly what `systemd-oomd` does, so leftovers will happen no matter how good the cleanup is and something has to clear them. The script prints what it found and, with `--kill`, stops it; printing must be the default so it is safe to run at any time. It must identify only this checkout's processes, by matching the absolute path of the repo root in the process command line, because several worktrees run suites concurrently on this machine and killing another checkout's live run would be far worse than the leak. It must further restrict to processes that are actually orphaned (parent pid 1, or the user's systemd manager) so a running suite's own app is never a candidate. It must cover Electron processes under this repo root, `Xvfb` servers whose `-auth` path is one of the `xvfb-run` temporary directories belonging to those Electron processes, `bun` control bridges under this repo root, and CLI processes started by the lan-share suite. Add a `reap` script to the root `package.json` so it is run as `bun run reap`, never invoked directly. `bash -n` must pass and `scripts/reap-test-processes.test.sh` from step 12 must pass.

10. **Add the leak check and wire it into each suite.** Add `count_test_processes` to `scripts/lib/process-control.sh`, using the same repo-root matching as the reaper, and call it at the start and end of `apps/desktop/smoke-tests.sh`, `apps/cli/smoke-tests.sh` and `apps/smoke-tests/run.sh`. When the end count exceeds the start count the suite prints the surviving command lines and exits non-zero even if every test passed, because a suite that leaks has failed. The comparison must tolerate another worktree's concurrent run by matching this repo root only. Do not add this to `scripts/test-everything-parallel.sh`: that file, `.githooks/pre-commit` and `scripts/install-hooks.sh` are frozen by `CLAUDE.md` and must not be edited by this plan, so each suite carries its own check instead.

11. **Add `scripts/lib/process-control.test.sh`.** Follows the pattern of `apps/smoke-tests/timeout.test.sh`: a `check` helper comparing expected and actual, a `WORK` directory from `mktemp -d` removed by an `EXIT` trap, a `fails` counter, and a non-zero exit when anything failed. It builds real process trees out of `sleep` and shell scripts, never an app, an emulator or a browser.

12. **Add `scripts/reap-test-processes.test.sh`.** Same pattern. It must prove the reaper's safety properties, not merely that it kills things, since a reaper that is too eager is more damaging than the leak it fixes.

13. **Document it.** Add a section to `docs/testing/README.md` covering: that suites clean up their own processes and check for leaks at the end; that `bun run reap` exists for leftovers a SIGKILLed run could not clean up; that it only ever touches this checkout's orphans, never another worktree's live run; and what a leak-check failure means when the tests themselves passed. Keep it to the length of the surrounding sections.

## Unit Tests

In `scripts/lib/process-control.test.sh`:

- `process_tree_pids` prints a parent and both its children, deepest first, for a two-level tree of `sleep` processes.
- `process_tree_pids` prints just the pid for a process with no children.
- `process_tree_pids` prints nothing for a pid that does not exist.
- `kill_process_tree` leaves no member of a three-deep `sleep` tree alive.
- `kill_process_tree` kills a child that ignores SIGTERM, proving the SIGKILL follow-up runs.
- `kill_process_tree` finds nothing to kill once the parent has already died and the children were reparented, which is the failure mode that motivates the group approach and must be demonstrated rather than asserted in a comment.
- `kill_process_group` kills that same reparented set, where `kill_process_tree` could not.
- `launch_in_process_group` starts the command, writes its log to the given file, and reports a pid that is alive.
- `launch_in_process_group` puts the command in a process group of its own, so `process_group_of <pid>` differs from the test's own pgid. Skipped with a printed `SKIP` line where `setsid` is absent, which is macOS.
- `launch_in_process_group` falls back to a plain background launch when `setsid` is not on `PATH`, driven by an empty `PATH` directory, and the returned pid is still alive and still killable.
- `process_group_of` prints empty for a dead pid rather than failing.
- `count_test_processes` counts a stub process whose command line contains this repo root, and does not count one whose command line contains a different path, which is the multiple-worktree case.

In `scripts/reap-test-processes.test.sh`:

- The reaper reports an orphaned stub whose command line contains this repo root.
- The reaper does not report a stub whose command line contains a different repo path, so another worktree's run is never a candidate.
- The reaper does not report a stub that still has a live parent, so a running suite's own app is never a candidate.
- Without `--kill` the reaper leaves every process it reported alive.
- With `--kill` the reported orphan is gone and the non-candidates are still alive.
- The reaper exits zero and prints a clear "nothing to reap" line when there is nothing to do, so it is usable from another script without special-casing.

## Smoke Tests

- Add a case to `scripts/lib/process-control.test.sh` that launches a stub through `launch_in_process_group`, kills the launching shell without a signal handler (`kill -9`), then reaps the leftover by group and asserts nothing survives. This is the SIGKILL path that no trap can cover, and it is the closest reproduction of the `systemd-oomd` event available without exhausting memory.
- Extend `apps/desktop/smoke-tests.sh` so a full run asserts its own leak check passes, which makes every existing Electron smoke test a leak test as a side effect. No new Electron test is needed for this.
- Add a case to `scripts/reap-test-processes.test.sh` that runs one real desktop smoke test to completion and asserts the reaper finds nothing afterwards, proving the per-test cleanup from step 5 works end to end. Use the fastest test, `1-load-fixture`.
- Add a case that starts one real desktop smoke test, SIGKILLs the test process mid-run, asserts Electron and `Xvfb` are left behind, then asserts `bun run reap --kill` clears them and `count_test_processes` returns to its starting value. This is the only check that covers the actual observed failure, and it must fail before step 5 is applied.

## Verify

- `bash -n` passes on every file this plan adds or edits.
- `bash ./scripts/lib/process-control.test.sh` passes with no failures.
- `bash ./scripts/reap-test-processes.test.sh` passes with no failures.
- `bun run compile` clean and `bun run test` passing.
- `bun run test:cli`, `bun run test:electron` and `bun run test:and` all pass, each ending with its leak check reporting no increase.
- After a full `bun run test:everything`, `bun run reap` reports nothing to reap. This is the headline check: today it would report a pile.
- `ps -eo pid,args | grep electron` finds no Electron process under this repo root once the suites have finished.
- The three frozen files are untouched: `scripts/test-everything-parallel.sh`, `.githooks/pre-commit` and `scripts/install-hooks.sh`.
- The step 13 documentation names only commands that exist, and every relative link added resolves to a file that exists.

## Notes

- **The cause is confirmed, not suspected.** All 19 desktop tests that define a `cleanup` kill the recorded pid directly, and none of them calls the `kill_app_tree` that exists for this purpose. The pid recorded by `start_app` is the `xvfb-run` wrapper. The live leftovers on this machine are two Electron instances at geometry `+0+0` and `+960+0`, which is the sender and receiver pair a share test launches, and two `Xvfb` servers, which is one per instance. The evidence matches the code path exactly.
- **`kill_app_tree` was already written for this and never adopted.** Its own comment describes the 354 process out-of-memory kill. The fix is largely to route the existing tests through the function that was added to save them, which is why step 5 touches 19 files and changes almost nothing in each.
- **Four copies of the same tree walk exist.** `apps/desktop/smoke-tests/lib/common.sh`, `apps/cli/smoke-tests-lan-share.sh`, `scripts/story-player.sh` and `scripts/test-everything-parallel.sh`. This plan consolidates the first three. The fourth is frozen and must be left alone, so one duplicate survives on purpose.
- **Cleanup alone cannot be sufficient, which is why the reaper exists.** A SIGKILL runs no handler, so an out-of-memory kill or a hard kill of a runner will always leave processes behind. Better cleanup reduces how often that happens; only a reaper clears what is already there.
- **The reaper is the dangerous part of this plan.** Several worktrees run suites at once on this machine, so a match that is too broad would kill a colleague run mid-test and produce a failure that looks like a real bug. The repo-root match and the orphan check are both required, and both have tests, for that reason.
- **The leak check must not become flaky.** It compares counts scoped to this repo root, taken at the start and end of the same suite, so another worktree starting or finishing during the run cannot move the number. If it proves flaky in practice, the fix is to tighten the match, not to delete the check.
- **Process groups over tree walks.** A tree walk finds nothing once the parent has died, because the children have been reparented, which is precisely the situation a leak leaves behind. A process group survives reparenting. `setsid` is Linux only, so macOS keeps the tree walk and the group tests skip there. That asymmetry is unavoidable and should be stated in the documentation rather than hidden.
- **Out of scope.** This plan does not reduce how much memory the suites use, does not change how many suites run at once, and does not touch `systemd-oomd` configuration. It removes the waste that made an ordinary run exhaust the machine.
