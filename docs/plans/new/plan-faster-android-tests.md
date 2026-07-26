# Faster Android Smoke Tests

## Overview

The Android mobile smoke tests (`bun run test:and`) run all 38 tests strictly one at a time against a single emulator. Timing inferred from the last run's `apps/smoke-tests/tests/*/tmp/app.log` timestamps puts the test loop at roughly 6.5 minutes (5-17s per test, plus one 74s outlier), on top of a build/sync/install prologue. The loop is dominated by waiting: every helper in `apps/smoke-tests/lib/common.sh` polls on a 1 second `sleep`, each test cold-launches the app, and one test (`37-lan-share-timeout`) deliberately waits out a real 60 second window. This plan makes the run faster in two ways: cheap latency reductions that need no architectural change, and a worker pool that spreads the tests across several emulators. The runner is deliberately kept platform-neutral so `bun run test:ios` continues to work unchanged with a single device slot.

Parallelising tests *within* one emulator was investigated and rejected: the app has a single `applicationId` (`au.com.codecapers.photosphere`) and a single `MainActivity`, so only one instance can run at a time, and all test state lives in one shared `files/` sandbox that `android_cleanup` wipes wholesale. Getting around that needs Gradle product flavours producing N differently-identified APKs, for a sub-linear speedup on one device's CPU. Multiple emulators is both simpler and faster.

## Issues

## Steps

### Phase 1: latency reductions (no architecture change, applies to Android and iOS)

1. **Reduce the poll interval in `apps/smoke-tests/lib/common.sh`.** Add a `POLL_INTERVAL_SECONDS` constant set to `0.2` alongside `DEFAULT_WAIT_TIMEOUT`, with a comment explaining that a 1 second poll adds up to a full second of dead time to every wait and there are dozens of waits per test. Convert `wait_for_bridge_port`, `wait_for_bridge`, `wait_for_ready`, `wait_for_log`, and `wait_for_value` (both definitions; see Notes about the duplicates) from counting seconds to counting ticks: compute `local ticks=$((timeout * 5))` and loop on the tick count while sleeping `$POLL_INTERVAL_SECONDS`, so the timeouts stay expressed in seconds at the call sites and keep their current values. Do the same for `android_wait_for_file` in `apps/smoke-tests/lib/android.sh`. Complete when `bun run test:and -- 1-load-fixture` passes.

2. **Delete the duplicate helper definitions in `apps/smoke-tests/lib/common.sh`.** `read_value` and `wait_for_value` are each defined twice (around lines 300/388 and 315/403); the second definition silently wins. Keep one of each (the later `read_value`, which avoids `grep -oP`, and the later `wait_for_value`, which defaults its timeout to `DEFAULT_WAIT_TIMEOUT`) and remove the earlier pair, merging any comment detail worth keeping. This halves the risk that step 1's edit is applied to the dead copy. Complete when `bun run test:and -- 5-add-secret` passes.

3. **Skip the reinstall when the APK on the device is already the one that was just built.** In `apps/smoke-tests/lib/android.sh`, add `android_apk_installed_matches()` that returns 0 when `adb shell pm list packages` reports `$APP_ID` present *and* the sha of `$ANDROID_APK` matches the sha recorded at `/data/local/tmp/psphere-apk.sha` on the device, and have `android_install` skip `adb install -r` (logging that it did) when it returns 0, otherwise install and then write the fresh sha to that path. Compare bytes, never timestamps or "did the build run" proxies, so a changed APK can never be skipped. Add the sha path to the list `android_cleanup` deliberately does *not* delete, and note why in its comment.

4. **Add an explicit build-skip escape hatch for iteration.** In `apps/smoke-tests/lib/android.sh`, make `android_build` return early with a clear log line when `PHOTOSPHERE_SKIP_BUILD` is set to `1`. Do not gate the build on a source checksum: a checksum that misses a file produces exactly the stale-build class of failure this repo forbids blaming. Document the variable in `docs/testing/README.md`.

5. **Stop `test:and:unit` re-running every Gradle task.** In `apps/android-frontend/package.json`, remove `--rerun-tasks` from the `test:unit` script so Gradle's incremental build and build cache apply.

6. **Enable Gradle parallelism and caching.** In `apps/android-frontend/android/gradle.properties`, uncomment/set `org.gradle.parallel=true`, and add `org.gradle.caching=true` and `org.gradle.daemon=true`, each with a one-line comment. Complete when `bun run build:and` succeeds twice in a row and the second run is faster.

### Phase 2: multiple emulators on the LAN bridge

7. **Make `apps/android-frontend/scripts/emulator.sh` bring up N emulator instances.** Replace the single `NETCARD_NAME="emu-netcard"` constant with a `netcard_name(index)` helper producing `emu-netcard-<index>`, and add a `PHOTOSPHERE_EMULATOR_COUNT` variable (default `1`). Change `bridge_up` to create and enslave one tap per index; change `bridge_down` to remove every `emu-netcard-*` link; change `bridge_is_up` to require tap 0. Change `start_emulator_bg` to loop over the indices, launching each with `-read-only` (which is what lets one AVD back several concurrent instances) plus its own `-wifi-tap "$(netcard_name $index)"`, and to log each to `/tmp/psphere-emulator-<index>.log`. Keep `-no-snapshot`; the cold-boot reason in the existing comment still holds.

8. **Make `emulator.sh` `cmd_status` report per-device.** Change it to enumerate every serial `adb devices` reports in `device` state, check each one's `wlan0` for a `192.168.55.x` address (by invoking `adb -s "$serial"`), print one `ready` / `not ready` line per serial plus a final count line, and exit 0 only when at least one device is ready. Keep the existing retry-a-few-times behaviour per device: an absent address is often transient. This function must stay read-only.

9. **Add device enumeration to `apps/smoke-tests/lib/android.sh`.** Add `android_ready_devices()` printing one serial per line for every attached device whose `wlan0` carries a `192.168.55.x` address, and rewrite `android_require_ready` to fail when that list is empty (keeping its current message that setting the emulator up is the human's job and that this script never touches it) and otherwise log how many devices the run will use. Add `android_device_slots()` as an alias for `android_ready_devices` and `android_export_device <serial>` which exports `ANDROID_SERIAL`. Complete when a single-emulator `bun run test:and -- 0-launch-and-navigate` still passes.

10. **Add matching device-slot hooks to `apps/smoke-tests/lib/ios.sh`.** Add `ios_device_slots()` which runs the existing simulator selection from `ios_prepare` and prints exactly one UDID, and `ios_export_device <udid>` which exports `IOS_SIMULATOR_UDID`. This keeps `run.sh` platform-neutral and leaves the iOS run single-slot, so its behaviour is unchanged.

11. **Install onto every device.** Change `android_install` and `android_cleanup` in `apps/smoke-tests/lib/android.sh` to operate on the device named by `ANDROID_SERIAL`, and have `run.sh` (step 14) call them once per slot. All `adb` invocations in these functions stay bare: `adb` honours `ANDROID_SERIAL` from the environment, which is also what makes the two tests that call `adb` directly (`tests/1-load-fixture/test.sh` and `tests/28-host-emulator-comms/test.sh`) work with no edit.

### Phase 3: the worker pool

12. **Create `apps/smoke-tests/lib/runner.sh`** with the queue and scheduling primitives, each with the `//`-style comment block this repo uses in shell (`#` blocks above the function):
    - `queue_init <queue_file> <test_path...>` writes the work list, one path per line.
    - `queue_pop <queue_file>` takes an exclusive `flock` on the queue file, prints and removes the first line, and prints nothing when empty. This is the only mutation point, so a test path can never be handed to two workers.
    - `test_has_marker <test_path> <marker_name>` returns 0 when the test's directory contains the named marker file. Mirrors `is_sequential` in `apps/desktop/smoke-tests.sh`.
    - `order_tests <test_path...>` prints the tests with `.slow`-marked ones first, remaining order preserved, so the longest test starts on a worker immediately rather than last.
    - `run_test <test_path> <log_file> <duration_file>` runs one test under `timeout`, recording the elapsed seconds.
    - `run_worker <slot> <queue_file> <exclusive_lock_file> <results_dir>` calls `${PLATFORM}_export_device "$slot"`, then loops popping tests; before running a `.exclusive`-marked test it acquires `flock` on the exclusive lock file for the duration of that test, so at most one such test runs across the whole pool at any moment. Writes a `pass`/`fail` line per test into `results_dir`.
    - `run_pool <results_dir> <test_path...>` creates the queue and exclusive lock under a `mktemp -d`, starts one `run_worker` background job per device slot, waits for them, and returns non-zero if any test failed.

13. **Create `apps/smoke-tests/runner.test.sh`**, a shell test in the style of `apps/smoke-tests/android-lock.test.sh` (a `check <description> <expected> <actual>` helper, a `fails` counter, a `mktemp -d` work dir and an `EXIT` trap). It must exercise the pure scheduling logic with no device and no real tests: see the Unit Tests section for the cases. Add `"test:runner": "./runner.test.sh"` to `apps/smoke-tests/package.json` scripts.

14. **Rewrite `main` in `apps/smoke-tests/run.sh` to use the pool.** Source `lib/runner.sh`; keep the existing filter argument, the `android_require_ready` gate, and the "no tests matched the filter is an error" behaviour. Then: run `${PLATFORM}_prepare` and `${PLATFORM}_build` once, read the device slots from `${PLATFORM}_device_slots`, and for each slot export it and run `${PLATFORM}_install`. Replace the sequential `for` loop with `order_tests` followed by `run_pool`. Change the `EXIT` trap so it runs `${PLATFORM}_cleanup` once per slot. Print the same pass/fail summary, sourced from the results directory, and additionally print each failing test's log path (as `apps/desktop/smoke-tests.sh` does) since parallel output is interleaved. Complete when `bun run test:and` passes end to end with one emulator attached.

15. **Redirect per-test output to a log file when more than one worker is running.** In `run_test`, write the test's stdout/stderr to `<test_dir>/tmp/test-run.log` and print only the `RUN`/`PASS`/`FAIL` lines with the duration, matching `apps/desktop/smoke-tests.sh`. With a single slot, keep streaming output to the terminal so the existing single-emulator experience does not regress.

16. **Add the exclusivity markers.** Create an empty `.exclusive` file in each of `apps/smoke-tests/tests/7-share-secret/`, `8-share-database/`, `9-share-roundtrip/`, `26-receive-database/`, `27-receive-secret/`, and `37-lan-share-timeout/`. All six put a LAN-share sender or receiver on the shared `192.168.55.0/24` segment, where discovery is a UDP broadcast to `255.255.255.255:54321`; two emulators on the one bridge hear each other, and `37-lan-share-timeout` specifically asserts that *no* receiver is found, so a concurrent `26` would break it. Create an empty `.slow` file in `apps/smoke-tests/tests/37-lan-share-timeout/`. Add a short `README.md` in `apps/smoke-tests/tests/` documenting both markers.

17. **Update the docs.** In `docs/testing/README.md`, document that `bun run test:and` now spreads tests across every ready emulator, how to bring up more than one (`PHOTOSPHERE_EMULATOR_COUNT=3 bun run emu:and:up`), the `.exclusive` and `.slow` markers, and `PHOTOSPHERE_SKIP_BUILD`. In `apps/android-frontend/scripts/emulator.md`, document `PHOTOSPHERE_EMULATOR_COUNT`, the one-tap-per-instance model, and `-read-only`. In `apps/android-frontend/CLAUDE.md`, extend the "DO NOT touch the emulator" section to make clear the rule covers all instances, and update the `status` description to the new per-device output.

## Unit Tests

Shell logic is tested with shell test scripts, matching the existing `apps/smoke-tests/android-lock.test.sh`. New or changed shell functions and their tests, all in `apps/smoke-tests/runner.test.sh` unless noted:

- `queue_init` - writes exactly the paths given, one per line, in order.
- `queue_pop` - returns lines in order; prints nothing and exits 0 on an empty queue; prints nothing and exits 0 on a missing queue file.
- `queue_pop` under concurrency - N background poppers draining a queue of M entries between them consume each entry exactly once and lose none (the mutual-exclusion proof, mirroring the stress test in `android-lock.test.sh`).
- `test_has_marker` - true for a directory containing the marker, false for one without, false for a missing directory.
- `order_tests` - `.slow`-marked tests come first; the relative order of the rest is unchanged; a list with no markers is returned unchanged.
- `run_test` - a passing script yields a `pass` result and a non-negative duration; a failing script yields `fail`; a script that hangs is killed by the timeout and yields `fail`.
- `run_worker` exclusivity - two workers over a queue of stub `.exclusive` tests that each record their start and end times never overlap; two workers over non-exclusive stubs do overlap (proving the lock is not accidentally serialising everything).
- `run_pool` - returns 0 when every stub test passes, non-zero when any fails, and runs every test in the queue exactly once.
- `android_apk_installed_matches` (new `apps/smoke-tests/android.test.sh`) - with `adb` stubbed on `PATH`: returns 1 when the package is not listed, 1 when the recorded sha differs, 0 when the package is listed and the shas match.
- `android_ready_devices` (same file, stubbed `adb`) - prints only serials in `device` state whose `wlan0` shows a `192.168.55.x` address; prints nothing when none qualify; handles multiple qualifying serials.
- `netcard_name` in `apps/android-frontend/scripts/emulator.sh` (new `apps/android-frontend/scripts/emulator.test.sh`) - returns `emu-netcard-0`, `emu-netcard-1` for indices 0 and 1. Only pure-function tests here: nothing in this file's test may create an interface, start an emulator, or need root.

No TypeScript changes are made, so no Jest tests change.

## Smoke Tests

The mobile smoke tests under `apps/smoke-tests/tests/` are themselves the end-to-end coverage, and this plan changes the harness that runs them, so the whole existing suite is the regression check. Specifically:

- `bun run test:and` with **one** emulator attached passes all 38 tests, proving the refactor did not regress the single-device path.
- `bun run test:and` with **three** emulators attached passes all 38 tests, and the wall-clock is materially lower than the single-emulator run.
- `bun run test:and -- 1-load-fixture` (single-test filter) passes, proving `ANDROID_SERIAL` reaches a test's own `adb` calls.
- `bun run test:and -- 28-host-emulator-comms` passes, proving the same for the guest-to-host reachability test.
- `bun run test:and -- 37-lan-share-timeout` with three emulators attached still measures a real window of at least 50s, proving the exclusive lock stopped the other emulators' LAN traffic from interfering.
- `bun run test:ios` passes unchanged, proving the platform-neutral single-slot path still works.
- `apps/smoke-tests/android-lock.test.sh` still passes: the whole-run lock is unchanged and one `test:and` run still owns every device.
- A second `bun run test:and` immediately after the first logs that it skipped the APK install (step 3) and still passes.

## Verify

- `bun run compile` succeeds (no TypeScript is changed, so this must stay clean).
- `bun run test` passes (all unit tests, including the unchanged `apps/smoke-tests` Jest tests).
- `bun run --filter=smoke-tests test:runner` passes (the new `runner.test.sh`).
- `apps/smoke-tests/android.test.sh` and `apps/android-frontend/scripts/emulator.test.sh` pass.
- `apps/smoke-tests/android-lock.test.sh` passes.
- `bun run test:and` passes with one emulator, and again with three.
- `bun run test:ios` passes.
- `bun run test:all` passes (unit tests plus the CLI and Electron smoke suites, none of which this plan touches).

## Notes

- **Measured baseline.** Per-test durations were inferred from the mtimes of `apps/smoke-tests/tests/*/tmp/app.log` from the last run: 35 tests totalling roughly 384s, ranging 4-17s, with `37-lan-share-timeout` at 74s (19% of the loop on its own).
- **Expected result.** Six tests are exclusive, totalling roughly 126s when serialised. The other 32 total roughly 258s. With three emulators the critical path is about `max(126, 258/3 + build) ~= 130s`, so the test loop should drop from around 6.5 minutes to a little over 2. Past three workers the exclusive group, and `37-lan-share-timeout` inside it, becomes the floor.
- **The next lever after this plan is test 37.** Its 60s window comes from `SHARE_TIMEOUT_MS` in `packages/node-api/src/lib/lan-share.worker.ts:17`, which is baked into the mobile worker bundle. Making it settable from test mode would need a value plumbed from the launch intent through the `JsEngine` plugin into the embedded worker, and the test's `< 50s` assertion rescaled (the regression it guards against collapsed 60s to about 12s, a 5x ratio a shorter window would still catch). That is a real design change to the worker's configuration surface, so it is deliberately left out of this plan rather than bolted on.
- **Why not parallelise within one emulator.** One `applicationId` and one `MainActivity` mean a second `am start` re-targets the running app rather than starting a second one; all state lives in one `files/` sandbox that `android_seed_database` writes and `android_cleanup` removes wholesale; database names already collide across tests (`test-db` is used by two); and the fixture push path `/data/local/tmp/50-assets` is a fixed name. Fixing all of that needs Gradle product flavours with distinct application ids, for a sub-linear win on one device's CPU.
- **Why not per-device locks.** `android-lock.sh` stays exactly as it is. One `test:and` run owns every attached device for its whole life, so a single machine-wide lock is still the correct and simplest model; splitting it per device would only matter if two independent runs had to share the machine, which is not a goal here.
- **The host side is already parallel-safe.** The control bridge binds an OS-assigned port (`PHOTOSPHERE_TEST_PORT=0`, read back from `bridge.port`), `adb forward tcp:0` lets adb assign the host port atomically, each test has its own `tmp/` directory, and `run_cli` already isolates the vault and config per test. `DEFAULT_WAIT_TIMEOUT` in `common.sh` was already doubled with a concurrent run in mind.
- **Reusing an app launch across tests was considered and rejected for now.** Every test cold-launches the app and starts its own bridge, which is a real per-test cost, but sharing a launch would couple tests to each other's state and undermine the isolation the suite currently gets for free. Parallelism buys more with less risk. Revisit only if the per-test launch shows up as the dominant cost after this plan.
- **The emulator remains the human's to manage.** Nothing in this plan starts, stops, restarts, or reconfigures an emulator from the test harness; `run.sh` keeps failing fast with the reason when no device is ready. Step 7 edits `emulator.sh` so a human can ask it for more instances; it does not make the harness call it.
