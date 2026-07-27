# Smoke test parity between Electron and mobile

## Overview

The Electron suite (`apps/desktop/smoke-tests/`) and the mobile suite (`apps/smoke-tests/tests/`) were built at different times and have drifted apart. There are 38 mobile tests and 24 Electron tests, the numbering no longer lines up (mobile starts at 0, both suites use 17 twice, and mobile has gaps at 25 and 38), and several tests that share a number are not the same test: the mobile port often only waits for a log line where the Electron version also asserts the persisted result. This plan defines a single list of 39 tests that is the same on both platforms, renumbers both suites to it, fills in what each platform is missing, and makes the mobile runner report results the way the Electron runner does. Every new or changed test must follow the existing conventions of the suite it lives in: the same directory layout (`<n>-<name>/test.sh`), the helper functions from that suite's `lib/common.sh`, the same header comment style, and the same scheduling markers.

## The test list

One list, numbered 1 to 39 with no gaps and no duplicates. A number identifies the same test on both platforms. Where a platform skips a test, that number is simply absent from that suite's directory listing.

Statuses: **Implemented** (exists and matches the other platform), **Requires change** (exists but is weaker than the other platform), **To implement** (should exist, does not yet), **Skip** (makes no sense on that platform).

| # | Test | Electron | Mobile | Old # (Electron / mobile) | Notes |
| --- | --- | --- | --- | --- | --- |
| 1 | launch-and-navigate | Skip | Implemented | - / 0 | Proves the mobile host-to-device control bridge round-trips. Electron has no bridge, and every Electron test starts the app and navigates anyway. |
| 2 | load-fixture | Implemented | Implemented | 1 / 1 | |
| 3 | create-database | Implemented | Implemented | 2 / 2 | |
| 4 | open-database | Implemented | Implemented | 3 / 3 | |
| 5 | import-photos | Implemented | Implemented | 4 / 4 | |
| 6 | add-secret | Implemented | Implemented | 5 / 5 | |
| 7 | add-database-entry | Implemented | Implemented | 6 / 6 | |
| 8 | share-secret | Implemented | Requires change | 7 / 7 | Electron runs a full two-party transfer between two app windows. Mobile drives the sender only and stops at the pairing code. |
| 9 | share-database | Implemented | Requires change | 8 / 8 | Same as 8. |
| 10 | view-secret | Implemented | Implemented | 9 / 9 | |
| 11 | view-database | Implemented | Implemented | 10 / 10 | |
| 12 | edit-encryption-key | Implemented | Requires change | 11 / 11 | Electron asserts the raw PEM and type survive the edit. Mobile only waits for "Secret updated". |
| 13 | edit-api-key | Implemented | Requires change | 12 / 12 | As 12. |
| 14 | edit-s3-credentials | Implemented | Requires change | 13 / 13 | As 12. |
| 15 | rename-secret | Implemented | Requires change | 14 / 14 | As 12. |
| 16 | duplicate-name | Implemented | Requires change | 15 / 15 | Electron asserts the original secret is untouched. Mobile asserts nothing and has no `check_no_errors`. |
| 17 | remove-recent-database | Implemented | Requires change | 16 / 16 | Mobile does not assert the entry actually left the recent list. |
| 18 | news-notifications | Implemented | Requires change | 17 / 17 | Electron covers two items, dismissal persistence and three startups. Mobile covers one item and one dismissal. |
| 19 | replicate-database | Implemented | Requires change | 17 / 17 | Electron verifies the replica files. Mobile dropped that as a host-side check; it can assert on device the way prefetch (37) does. |
| 20 | move-file | Implemented | Implemented | 18 / 18 | Neither verifies the asset landed in the target database. Equal on both platforms, so out of scope here. |
| 21 | download-single-asset | Implemented | Requires change | 19 / 19 | Electron verifies the saved file. Mobile only waits for the completion log line. |
| 22 | download-multiple-assets | Implemented | Requires change | 20 / 20 | As 21. |
| 23 | import-video | To implement | Implemented | - / 21 | The ffprobe/ffmpeg import path is untested through the Electron app. |
| 24 | edit-database-origin | Implemented | Requires change | 22 / 22 | Electron verifies `.db/config.json`. Mobile dropped that as a host-side check and can assert it on device. |
| 25 | developer-screen | Implemented | To implement | 23 / - | The mobile port omits the DevTools toggle, which is Electron only. |
| 26 | sync-settings | Implemented | To implement | 24 / - | The Configuration dialog and both toggles are in shared `packages/user-interface`. |
| 27 | receive-database | Skip | Implemented | - / 26 | Already covered on desktop, in both directions, by `cli-desktop-lan-share-smoke-tests.sh`. |
| 28 | receive-secret | Skip | Implemented | - / 27 | As 27. |
| 29 | host-emulator-comms | Skip | Implemented | - / 28 | Emulator bridge connectivity. No desktop equivalent. |
| 30 | stale-recent-database | To implement | Implemented | - / 29 | Clicking a recent entry whose files are gone is a real desktop case and is untested. |
| 31 | export-asset | Skip | Implemented | - / 30 | Covers cancelling the native share sheet. Desktop writes straight to disk, covered by 21 and 22. |
| 32 | create-database-no-collision | To implement | Implemented | - / 31 | On Electron this is "creating a database into a non-empty folder is rejected", the shared behaviour underneath. |
| 33 | encrypted-database | To implement | Implemented | - / 32 | The CLI encrypted suite covers the CLI. Nothing opens an encrypted database through the Electron app. |
| 34 | s3-database | To implement | Implemented | - / 33 | Opt-in on `TEST_S3_BUCKET`, skipping cleanly when unset, as the mobile test does. |
| 35 | sync | To implement | Implemented | - / 34 | Electron's sync-settings test (26) covers the gate and persistence, not an actual sync run. |
| 36 | database-summary | To implement | Implemented | - / 35 | No Electron coverage of the database summary page. |
| 37 | prefetch-database | To implement | Implemented | - / 36 | No Electron coverage of prefetch into a partial replica. |
| 38 | lan-share-timeout | Skip | Implemented | - / 37 | Exists to catch the mobile embedded-engine virtual clock racing ahead. Electron uses real timers, and the test costs a real 60 seconds. |
| 39 | secret-in-keychain | Skip | Implemented | - / 39 | Desktop keychain storage is covered by `apps/cli/smoke-tests-key-chain`. |

## Issues

## Steps

Each step is complete when `bun run compile` is clean, `bun run test` passes, and the tests it touches pass on their own (`bun run test:electron -- <n>` for Electron, `bun run test:and -- <n>` for mobile). The renumbering steps come first so every later step creates or edits a test at its final number.

1. Stop the mobile runner streaming test output to the terminal, matching how the Electron runner handles logs. Delete the `RUNNER_STREAM_OUTPUT` variable from `apps/smoke-tests/lib/runner.sh` (its declaration near the top, the branch in `run_pool` that sets it to 1 for a single worker, and the `tee` branch in `run_test`), leaving `run_test` to always redirect the test to its log file the way `apps/desktop/smoke-tests.sh` does. The reporting skeleton already exists: `run_worker` prints a `RUN` line per test, then `PASS` or `FAIL` with a log path on failure, and `run.sh` repeats every failing test's log path under the summary. Step 2 extends what those two places print. Do not copy the Electron runner's end-of-run `cat` of each failed log (`FAILED_TEST_LOGS` in `apps/desktop/smoke-tests.sh`), because that puts full test output back into the main output, which is what this step removes. Update the sentence in `docs/testing/README.md` that says a single device keeps streaming to the terminal.
2. Capture the device log for each mobile test, and make a failure reference every log it produced. Today a failing test names only `test-run.log`, `app.log` is never mentioned even though it sits beside it, and nothing off the device is kept at all, so a native crash, an ANR, a Java or Kotlin stack trace, or the embedded engine dying leaves no trace on the host. Three parts:
    - **Capture.** Add `${PLATFORM}_clear_device_log` and `${PLATFORM}_capture_device_log <dest>` to `apps/smoke-tests/lib/android.sh` and `apps/smoke-tests/lib/ios.sh`, following the naming and structure of the existing platform hooks (`android_export_device`, `android_ensure_apk`, `ios_export_device`). Android clears with `adb logcat -c` and dumps with `adb logcat -d`, both against the exported `ANDROID_SERIAL`; when the clear is refused (some devices reject it) fall back to recording a start timestamp and dumping with `adb logcat -d -t <timestamp>`. The iOS simulator log cannot be cleared, so `ios_clear_device_log` records a start time and `ios_capture_device_log` runs `xcrun simctl spawn <udid> log show --style syslog --start <time>` narrowed to the app process. Use only flags available on Xcode 14.2 and macOS 12.7.6.
    - **Scope and placement.** Call both from `run_worker` in `apps/smoke-tests/lib/runner.sh`, inside the existing `if [ -n "$ACQUIRED_DEVICE" ]` branch so the runner's own tests, which run with empty device slots, never reach for a device. Clear immediately after `${PLATFORM}_ensure_apk` and before the test runs, which scopes the capture to that test alone because a worker holds its device exclusively for the whole test. Capture into `<tmp>/device.log` only when the test failed, and before `release_device`, while the device is still held and still exported. Raise the logcat ring buffer once in `android_prepare` (`adb logcat -G 16M`) so a chatty test does not lose its earliest lines, rather than per test.
    - **Reference every log.** Change the `FAIL` line in `run_worker` and the failing-test list in `run.sh` to print `test-run.log`, `app.log` and `device.log` rather than just the first. `app.log` is always `<tmp>/app.log` on mobile, because every test calls `start_app "$TMP_DIR"` with the directory the run's logs live in. Print a path only when the file exists: a test that fails before acquiring a device has no `device.log`, and one that fails before starting the app has no `app.log`. Do the same in `apps/desktop/smoke-tests.sh`, which has the identical gap of naming only `test-run.log`, except that Electron tests may run more than one app instance under one tmp directory (`7-share-secret` uses `sender/` and `receiver/`), so it should list every `app.log` found under the test's tmp directory rather than assuming one fixed path.
3. Renumber the mobile suite to the table above by renaming each `apps/smoke-tests/tests/<old>-<name>/` directory. Rename in descending number order (or via a temporary prefix) so a rename never lands on a directory that still exists. The `.exclusive` marker files move with their directories.
4. In each renamed mobile `test.sh`, update the `print_test_header <n>` argument and the trailing `log_success "Test <n> passed: ..."` line to the new number, and update any cross-reference in the header comment that names another test by number. There are five, given here as the reference the comment makes today and what it becomes: `23-import-video` cites test 4, now 5; `31-export-asset` cites tests 19 and 20, now 21 and 22; `36-database-summary` cites test 36, now 37; `37-prefetch-database` cites test 8, now 9; `38-lan-share-timeout` cites test 7, now 8. References to plan steps ("step 11", "substep 12a") are not test numbers and stay as they are. The headers of `36-database-summary` and `37-prefetch-database` also claim the 0-24 range mirrors the desktop suite, which the new numbering replaces. Drop the stale "fails fast at the unimplemented open-database command" sentences in `20-move-file`, `21-download-single-asset` and `22-download-multiple-assets` while editing those files, since those commands now work.
5. Renumber the Electron suite the same way: rename each `apps/desktop/smoke-tests/<old>-<name>/` directory, update `print_test_header` and the trailing `log_success` line, and move the `.sequential` markers with their directories.
6. Update `apps/smoke-tests/runner.test.sh`: its fixtures name real tests (`12-edit-api-key`, `22-edit-database-origin`, `29-stale-recent-database`, `2-create-database`, `8-share-database`), so change them to the new numbers, keeping each case testing what it tested before. The two "a shared number selects two tests" cases no longer describe reality, because no number is used twice now. Keep the cases as synthetic fixtures that prove a numeric filter can match more than one name, and reword the comment to say so.
7. Update the docs for the new numbering: the `numbered 0-39` phrasing in both places in `docs/testing/README.md`, the `bun run test:and -- 26` example there, and the `.exclusive` test list in `apps/smoke-tests/tests/README.md`.
8. Add `apps/desktop/smoke-tests/23-import-video/test.sh`, porting mobile 23: import `test/multiple-files/test.mp4` through the import UI and assert it lands in the gallery.
9. Add `apps/desktop/smoke-tests/30-stale-recent-database/test.sh`, porting mobile 30: open a real database, click a recent entry whose directory does not exist, assert the "Database not found" warning fires and the open database is left untouched.
10. Add `apps/desktop/smoke-tests/32-create-database-no-collision/test.sh`: create two databases in a row into separate folders and assert both succeed, then assert creating into an existing non-empty database folder is rejected.
11. Add `apps/desktop/smoke-tests/33-encrypted-database/test.sh`, porting mobile 33: create and encrypt a database with the CLI, store the private key as an `encryption-key` secret, open it in the app, assert the gallery loads decrypted assets.
12. Add `apps/desktop/smoke-tests/34-s3-database/test.sh`, porting mobile 34: opt in on `TEST_S3_BUCKET`, log a skip line and exit 0 when unset, and cover the same three cases (a populated bucket lists, a bad credential surfaces an error rather than an empty list, a bad certificate fails closed).
13. Add `apps/desktop/smoke-tests/35-sync/test.sh`, porting mobile 35: make an edit, assert the sync runs start to finish and the navbar spinner appears then clears.
14. Add `apps/desktop/smoke-tests/36-database-summary/test.sh`, porting mobile 36: open a seeded database, navigate to the database summary page, assert it loads with data.
15. Add `apps/desktop/smoke-tests/37-prefetch-database/test.sh`, porting mobile 37: partially replicate a database, open the partial replica, assert the prefetch copies the missing thumbnails in.
16. Add `apps/smoke-tests/tests/25-developer-screen/test.sh`, porting Electron 25: enable developer mode by tapping the About version label, open the developer screen, open and leave Stories, toggle the FPS indicator on and off. Omit the DevTools section.
17. Add `apps/smoke-tests/tests/26-sync-settings/test.sh`, porting Electron 26: toggle "Enable syncing" and "Only sync over Wi-Fi", assert each recomputes the sync gate and that both values persist across a restart, reading the persisted values back from the device rather than from a host TOML file.
18. Complete mobile 8 and 9 (`share-secret`, `share-database`): finish the transfer instead of stopping at the pairing code, with the host CLI acting as the receiver over the LAN bridge. This is the mirror of mobile 27 and 28, which already drive the CLI as sender against the app as receiver, and it is what `cli-desktop-lan-share-smoke-tests.sh` does in both directions for desktop. Both tests already carry `.exclusive`, and the `require_lan_bridge` guard belongs at the top as it is in 27 and 28.
19. Strengthen mobile 12, 13, 14 and 15: assert the secret's persisted value and type round-trip unchanged after the edit.
20. Strengthen mobile 16: assert the original secret is unchanged, and add `check_no_errors` with the expected duplicate-name error filtered out, as the Electron version does.
21. Strengthen mobile 17: assert the removed entry is gone from the recent list.
22. Strengthen mobile 18 to the full multi-item, dismissal-persistence and three-startup lifecycle the Electron version covers.
23. Strengthen mobile 19: assert the replica contents on device, the way mobile 37 asserts prefetched thumbnails.
24. Strengthen mobile 21 and 22: assert the exported files exist on the device with the expected content.
25. Strengthen mobile 24: assert the edited origin is persisted, reading it back from the device.
26. Review the scheduling markers for the new Electron tests and mark 33, 34 and 37 `.sequential` if they prove unstable in a parallel batch. None of the new tests puts a LAN-share peer on the network, so no new `.exclusive` markers are expected on the mobile side.

## Unit Tests

No new or changed TypeScript functions are planned. If a step turns out to need a new `data-id` or a new test-driver command in `packages/user-interface/src/lib/test-driver.ts`, or a new route in `apps/smoke-tests/lib/control-bridge.ts`, that step must also add a unit test for it under the owning package's `src/test/` directory. Prefer reusing the existing `get-value` and `get-storage` commands before adding anything new, and never add a platform-specific channel.

Step 2 does add shell functions, and `apps/smoke-tests/runner.test.sh` is where the runner's own logic is tested, so add cases there:

- `run_worker` names every log that exists on a failure. Drive it with a failing stub whose tmp directory already holds an `app.log`, and assert the `FAIL` line contains both that path and the `test-run.log` path.
- `run_worker` omits a log that does not exist, so a failing stub with no `app.log` produces a `FAIL` line naming only `test-run.log`.
- `run_worker` does not reference a device log when no device was acquired, which is the empty-slot case the existing pool tests already run in.

The `${PLATFORM}_clear_device_log` and `${PLATFORM}_capture_device_log` hooks talk to a real emulator or simulator, so they are covered by the smoke run itself rather than by unit tests, the same as every other platform hook.

## Smoke Tests

The plan is almost entirely smoke tests: eight new Electron tests (steps 8-15), two new mobile tests (steps 16-17), and nine strengthened mobile tests (steps 18-25). `apps/smoke-tests/runner.test.sh` is the existing test for the mobile runner's own filter logic and is updated in step 6. Steps 1 and 2 change the runners rather than a test. Verify them by running `bun run test:and` against a single device and confirming that no test output reaches the terminal (only the `RUN`, `PASS` and `FAIL` lines), and by making a test fail deliberately and confirming the `FAIL` line and the summary both name its `test-run.log`, `app.log` and `device.log`, that all three exist, and that `device.log` holds logcat output from that test alone.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bash apps/smoke-tests/runner.test.sh` passes.
- `bun run test:electron` passes, including the eight new tests.
- `bun run test:and` passes, including the two new tests and the strengthened ones.
- `bun run test:ios` passes if a macOS machine is available. The mobile tests are platform-neutral, so no iOS-specific work is expected.
- `bun run test:and -- <n>` and `bun run test:electron -- <n>` select the right test for every new number.
- The S3 test skips cleanly with a logged skip line when `TEST_S3_BUCKET` is unset.
- `bun run test:and` against a single device prints only the `RUN`, `PASS` and `FAIL` lines plus the failing log paths. No test output reaches the terminal, and each test's full output is in its `tests/<name>/<tmp>/test-run.log`.
- A deliberately failing mobile test names `test-run.log`, `app.log` and `device.log` on its `FAIL` line and again in the summary, all three exist, and `device.log` contains logcat output from that test only (nothing from the test that ran before it on the same device).
- A deliberately failing Electron test names its `test-run.log` and every `app.log` under its tmp directory.

## Notes

- The unified list is 1 to 39 with no gaps. Each suite runs the subset it implements, so the Electron directory listing starts at 2 and has holes. Both runners discover tests by scanning directories and sorting, so holes are fine.
- Renumbering churns nearly every file in both suites. It is worth doing once: today the number 17 means two different tests, mobile 21 and Electron 21 are different tests, and there is no way to talk about "test 12" without naming the platform.
- Mobile tests read much shorter than their Electron counterparts largely because `apps/smoke-tests/lib/common.sh` has more helpers (`create_database`, `add_secret_via_ui`, `run_cli`, `assert_value`) while Electron tests inline their cleanup and shell out to `python3` for host file assertions. Length is not the gap. The gap is the missing assertions called out in the table.
- Mobile cannot run two app instances on one device, which is why mobile 8 and 9 stopped at the pairing code. Step 18 closes that with the CLI as the second party, which is a stronger test than the app talking to itself: it puts two independent implementations of the protocol on the wire.
- Tests 31 and 38 are deliberately mobile-only, and 1, 27, 28, 29 and 39 deliberately have no Electron counterpart. The table is the record of why.
- Step 1 leaves the two runners deliberately not identical. The Electron runner also dumps every failed test's log to the terminal after the summary, which the mobile runner will not do: the point of the step is to keep test output out of the main output, and a path is enough to open the file. Everything else about the mobile runner's reporting already matches Electron.
- Streaming was only ever on for a single-device run, so this changes nothing about a pool run. It changes what a developer sees on one emulator, which is the common case for iterating on a test.
- Step 2 makes step 1 safe. Taking the streamed output away without keeping more evidence would leave less to debug from than before, not more. After both steps a failure points at the test's own output, the app's own log, and the device's native log, none of which existed together on the host until now.
- `device.log` is captured only for failures. Capturing every test's logcat would cost a dump per test and fill the tmp directories, and a passing test's device log is never read. The buffer still holds the test's output at the moment the verdict is known, so nothing is lost by deciding late.
- The mobile `app.log` is not pulled off the device either, before or after this change. The app forwards each log line over the control bridge as it happens and `control-bridge.ts` appends it host-side, so it is already on the host by the time a test fails.
