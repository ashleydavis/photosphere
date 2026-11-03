# Read the App Log on Every Platform and Fail Manual Tests on Unexpected Errors

## Overview

When an agent takes a manual e2e test (from `docs/testing/e2e/CHECKLIST.md`), it has no documented way to read the Photosphere App's log. On Android the agent had to search the app's files to find `files/logs`, and its first guess at the path was wrong. Errors that reach only the log (such as `Replication error: ReadOnlyFileSystem`) are easy to miss, and steps can pass even when the app logged an error the test never expected. This plan does two things. It adds one script, `bun run app:log`, that prints the app's main log or errors log on Linux, macOS, Windows, Android and the iOS simulator. It also adds a rule to both walkthrough commands and to the checklist: the agent reads the errors log before and after every step, and any new `[ERROR]` line or on-screen error that the test does not expect fails the step and the test.

## Issues

## Steps

- [x] 1. **Write `apps/photosphere/scripts/app-log.sh`.** It is a new bash script (`#!/usr/bin/env bash`, `set -euo pipefail`, executable bit set, file comment block naming its single job: print the Photosphere App's log file from the device or computer the app runs on). Usage: `app-log.sh --platform <linux|macos|windows|android|ios> [--target <adb serial or simulator udid>] [--errors] [--from-line <line number>] [--path]`. With no arguments it prints usage to stderr and exits 2, the same way `scripts/start-minio.sh`'s `usage` does.
    - The log folder is `<logs parent>/logs`, as `startFileLog` in Ziggy's `packages/ziggy/core/src/lib/core.zig` makes it: `<logs parent>` is `$PHOTOSPHERE_LOG_DIR` when it is set, otherwise the app's data directory. The data directory for each platform is:
        - `linux`: `${XDG_DATA_HOME:-$HOME/.local/share}/au.com.codecapers.photosphere` (Ziggy's `native/linux/src/lib/native-app.zig` uses `g_get_user_data_dir()` plus `.app_id` from `apps/photosphere/native/linux/src/main.zig`).
        - `windows`: `$LOCALAPPDATA/au.com.codecapers.photosphere` (Ziggy's `native/windows/src/lib/native-app.zig`; `.app_id` from `apps/photosphere/native/windows/src/main.zig`). The script fails with a message naming `LOCALAPPDATA` when that variable is unset.
        - `macos`: `$HOME/Library/Application Support/au.com.codecapers.photosphere` (Ziggy's `native/macos/.../ZiggyBridge.swift` uses Application Support plus the bundle identifier `PRODUCT_BUNDLE_IDENTIFIER` from `apps/photosphere/native/macos/Photosphere.xcodeproj/project.pbxproj`).
        - `android`: `files` inside the app's sandbox (`getFilesDir()` in Ziggy's `ZiggyNativeApp.java`). Every read goes through `adb -s <serial> exec-out run-as au.com.codecapers.photosphere.ziggy <command>`, with relative paths such as `files/logs`. When `PHOTOSPHERE_LOG_DIR` is set, the script uses it as an absolute path on the device instead. Source `apps/photosphere/scripts/android-common.sh` to get `adb` on the PATH (through `android-env.sh`) and `PHOTOSPHERE_ANDROID_APP_ID`. The device is chosen by the script itself, without `photosphere_android_pick_device`, so that reading a log never takes a pool emulator's device lock. Without `--target`, the script uses the only device `adb devices` lists in the `device` state. When there is no such device, or more than one, it fails with a message that lists the serials and asks for `--target`.
        - `ios`: `<data container>/Library/Application Support/au.com.codecapers.photosphere.ziggy` on the simulator, where `<data container>` is `xcrun simctl get_app_container <udid> au.com.codecapers.photosphere.ziggy data`. This is the path `photosphere_ios_storage_root` in `apps/photosphere-smoke-tests/lib/ios.sh` prints, and the bundle id `apps/photosphere/scripts/reset-ios.sh` uses. Without `--target`, use the single booted simulator from `xcrun simctl list devices booted`. When there is none, or more than one, fail with a message that lists them. When the container cannot be found, fail with a message saying the app is not installed on that simulator.
    - It picks the newest file in the log folder that matches `photosphere-????-??-??T??-??-??.log` (the main log). With `--errors` it uses the matching `photosphere-????-??-??T??-??-??-errors.log` instead. The names sort by time, so the newest is the last one in `ls` order. When the folder or the file is missing, the script fails with a message naming the full path it looked in.
    - `--path` prints the chosen file's path and nothing else. That lets a caller see that a restart has started a new log file.
    - `--from-line <n>` prints the file from line `n` onward (`tail -n +<n>`). Without it, the whole file is printed. `n` must be a positive integer: anything else fails with a message.
    - Unknown arguments, a missing value after an option or an unknown platform each fail with a message and the usage line.
    - Run `bash -n apps/photosphere/scripts/app-log.sh` and require exit 0.

    **Summary:** Wrote `apps/photosphere/scripts/app-log.sh` with the executable bit set. `bash -n` exits 0. Decisions: `android-env.sh` does not put `adb` on the PATH, so the script calls `$ANDROID_HOME/platform-tools/adb`, as `photosphere_android_pick_device` does. On Windows the `LOCALAPPDATA` message is raised only when `PHOTOSPHERE_LOG_DIR` is also unset, because that variable replaces the data directory. The Android folder check runs `run-as ... ls -d <folder>` and compares the output, because `adb exec-out` does not pass the exit code back. A physical iOS device is detected as a `--target` that `xcrun simctl list devices` does not list.

- [x] 2. **Wire up the script in `package.json` files.** In `apps/photosphere/package.json`, add `"app:log": "bash ./scripts/app-log.sh"` next to `"android:reset"`. In the root `package.json`, add `"app:log": "bash ./apps/photosphere/scripts/app-log.sh"` next to `"android:reset"`. It calls the script directly rather than going through `bun run --filter=ziggy`, so that arguments after `--` reach the script the way `"start-minio"` passes them. Run `mise exec -- bun run app:log` from the repo root. It must print the usage line and exit 2.

    **Summary:** Added `app:log` to both `package.json` files next to `android:reset`. `mise exec -- bun run app:log` printed the usage line and exited 2. `bun run --filter=ziggy app:log` did the same.

- [x] 3. **Try the script on Linux against a real app.** Run each command from the repo root. Set `MISE_DATA_DIR` back to the normal mise data folder for every `mise exec`, because exporting `XDG_DATA_HOME` moves it too.
    - Build: `mise exec -- bun run --filter=ziggy bundle:ui`, then `mise exec -- zig build photosphere-linux -p tmp/app-log-check`.
    - Start the app hidden in the background from bash and record its pid with `$!` in `tmp/app-log-check/app.pid`: `xvfb-run -a env WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 PHOTOSPHERE_TEST_MODE=1 XDG_DATA_HOME="$PWD/tmp/app-log-check/data" tmp/app-log-check/photosphere/photosphere &`. Wait until `tmp/app-log-check/data/au.com.codecapers.photosphere/logs` holds a `photosphere-*.log`, polling once a second for up to 60 seconds.
    - Run `XDG_DATA_HOME="$PWD/tmp/app-log-check/data" mise exec -- bun run app:log -- --platform linux`. The output must start with the log header Ziggy writes (the `Photosphere` title line and `--- System Information ---`).
    - Run the same command with `--errors`. It must print the errors log header ending `--- Error Log Start ---`.
    - Run it with `--path`. It must print one path under `tmp/app-log-check/data/au.com.codecapers.photosphere/logs/`.
    - Run it with `--from-line 3`. Its output must equal the main log without its first two lines (compare with `tail -n +3` of the file from `--path`, using `cmp`).
    - Run it with `--from-line 0`, `--from-line x` and `--platform nope`. Each must exit non-zero with a message.
    - Run it with `XDG_DATA_HOME="$PWD/tmp/app-log-check/empty"`. It must exit non-zero with a message naming `tmp/app-log-check/empty/au.com.codecapers.photosphere/logs`.
    - Stop the app with `kill_process_tree "$(cat tmp/app-log-check/app.pid)"` from `scripts/lib/process-control.sh`, run in bash. Check that the pid no longer exists. Never kill by name.

    **Summary:** Every check passed. The main log began with the `Photosphere` title and `--- System Information ---`. `--errors` ended `--- Error Log Start ---`. `--path` printed one file under `tmp/app-log-check/data/au.com.codecapers.photosphere/logs/`. `cmp` of `--from-line 3` against `tail -n +3` exited 0. `--from-line 0`, `--from-line x`, `--platform nope` and the `empty` data folder each exited non-zero with a message (the last naming `tmp/app-log-check/empty/au.com.codecapers.photosphere/logs`). `PHOTOSPHERE_LOG_DIR` also moved the folder as expected. The app was stopped with `kill_process_tree` and its pid was gone. Deviations: `zig build photosphere-linux -p tmp/app-log-check` puts the executable at `tmp/app-log-check/bin/photosphere`, so that path was started. The worktree had no built third-party libraries, so each of `aws`, `zlib-ng`, `imagemagick` and `ffmpeg` was built with `zig build -Dtarget=native-native` first. The harness refuses `source` inside `bash -c`, so the stop ran from `tmp/app-log-check/stop-app.sh`, which sources `scripts/lib/process-control.sh` and calls `kill_process_tree`.

- [x] 4. **Try the script on Android.** At this point, run `mise exec -- bun run emu:and:pool:status -- --quiet`. When it exits 1, skip this step and record in the step that the pool was down. When it exits 0:
    - Choose a pool serial from `adb devices` whose device lock `/tmp/photosphere-android-device-<serial>.lock` is free (`flock -n <lock> true` exits 0). Run `mise exec -- bun run android -- --target <serial>` to install and start the app.
    - Run `mise exec -- bun run app:log -- --platform android --target <serial>`. The output must start with the Ziggy log header. Run it with `--errors` and with `--path`. `--path` must print a path under `files/logs/`.
    - Run it without `--target` while more than one device is attached. It must exit non-zero with a message that lists the serials.
    - Run it with `--target emulator-1` (a serial that is not attached). It must exit non-zero with a message.

    **Summary:** The pool check exited 0. `emulator-5562`'s device lock was free, and `bun run android -- --target emulator-5562` installed and started the app. The main log began with the Ziggy header (`Photosphere`, `--- System Information ---`, `Platform: android`), `--errors` ended `--- Error Log Start ---`, and `--path` printed `files/logs/photosphere-<start time>.log`. Without `--target`, with five emulators attached, it exited 1 listing every serial. `--target emulator-1` exited 1 naming the attached devices. A missing `PHOTOSPHERE_LOG_DIR` folder exited 1 naming the folder. Fix made here: the `--target emulator-1` message listed the serials one per line, so they are now joined on one line. Deviation: the worktree had no Android builds of the third-party libraries, so each one was built with `zig build -Dtarget=x86_64-linux-android --libc apps/photosphere/native/android/app/build/ziggy/zig-libc/x86_64.txt`, the libc file `bun run android` writes. The app was left running on `emulator-5562`.

- [x] 5. **Add the error rule to `.claude/commands/test/manual-walkthrough.md`.** Under `## For each test`, step 4, change the `"y"` paragraph and the `"d"` handling:
    - Before each step under `## Test` and `## Check`, the agent records the errors log's file (`bun run app:log -- --platform <p> --target <t> --errors --path`) and its line count. This applies whoever runs the step. After the step, it reads the new lines with `--from-line <count + 1>`. When the path has changed (the app restarted), it reads the whole new file.
    - For a step the agent runs (`y`), the new errors log lines go inside the `>>-`/`<<-` block, after the command output, under a line `errors log:`. When there are none, that line says `errors log: no new lines`.
    - For a step the human reports with `d`, the agent still reads the new errors log lines. When they include an unexpected error, it reports the step the same way as a `y` step whose result does not match.
    - Add a rule under `## Rules`: "**An unexpected error fails the test.** A new `[ERROR]` line in the app's errors log, or an error shown on screen, that the test's expectations do not name makes the step 🔴 and the test fails (`- [-]`). Copy the error into the note word for word. `[WARN]` lines are listed in the result but do not fail a step on their own."
    - Under `## Driving the desktop app yourself`, add a bullet: the log of an app started this way is read with `bun run app:log -- --platform linux`, with the same `XDG_DATA_HOME` the app was started with.

    **Summary:** In step 4 of `## For each test`, added a bullet for reading the errors log before and after each Test and Check step, put the `errors log:` lines inside the `>>-`/`<<-` block of a "y" step, and made a "d" step read the new lines and report an unexpected error as a mismatch. Added the rule under `## Rules`, word for word, and the `app:log` bullet under `## Driving the desktop app yourself`.

- [x] 6. **Add the error rule to `.claude/commands/test/auto-walkthrough.md`.**
    - Under `## Running a test`, add a bullet: before and after every step under Test and Check, read the errors log of every app the test has started with `bun run app:log` (`--errors --path` and the line count before, `--from-line` after), as in `manual-walkthrough.md`.
    - Under `## Deciding the result`, add a bullet with the same rule text as step 5. Also say that the subagent's report for a failed test includes the error lines word for word.

    **Summary:** Added the errors log bullet under `## Running a test` (including reading the whole new file after a restart, as in `manual-walkthrough.md`) and the rule under `## Deciding the result` with the same text as step 5, plus the sentence that a subagent's report includes the error lines word for word.

- [x] 7. **Write the documentation.**
    - Create `apps/photosphere/scripts/app-log.md` in the layout of `apps/photosphere/scripts/reset-android.md`: what it prints, how it is invoked (`bun run app:log -- --platform <p> [...]` from the repo root, or `bun run --filter=ziggy app:log -- ...`), each argument, the log folder for each platform from step 1, that `PHOTOSPHERE_LOG_DIR`, `XDG_DATA_HOME` and `LOCALAPPDATA` move it, and that it takes no device lock. It also says that on iOS the script reads only from the simulator.
    - In `docs/testing/e2e/agent-driving.md`, add a `## Reading the app log` section before the platform sections. Say that `bun run app:log -- --platform <p> [--target <t>] [--errors]` prints the app's log on every platform, that `--path` and `--from-line` are how a step's new lines are read, and link to `../../../apps/photosphere/scripts/app-log.md`.
    - In `docs/testing/e2e/CHECKLIST.md`, add a paragraph after the **Do not skip prep.** paragraph: "**An unexpected error fails the test.** Read the app's errors log (`bun run app:log -- --platform <p> --errors`) before and after every step. A new `[ERROR]` line, or an error shown on screen, that the test does not expect fails the test."
    - In `docs/testing/e2e/README.md`, after the paragraph that names `bun run android:reset`, add one sentence: `bun run app:log` prints the app's log on any platform, linking to `../../../apps/photosphere/scripts/app-log.md`.

    **Summary:** Wrote `apps/photosphere/scripts/app-log.md` in the layout of `reset-android.md`: what it prints, how it is invoked, each argument, the log folder for each platform, how `PHOTOSPHERE_LOG_DIR`, `XDG_DATA_HOME` and `LOCALAPPDATA` move it, that it takes no device lock and that iOS reads only from the simulator. Added `## Reading the app log` to `docs/testing/e2e/agent-driving.md` before the platform sections, the paragraph after **Do not skip prep.** in `CHECKLIST.md`, and the sentence after the `android:reset` paragraph in `docs/testing/e2e/README.md`.

- [x] 8. **Run the tests.** Run `mise exec -- bun run tev 2>&1 | tee tmp/tev-app-log.log` from the repo root, in the background, and require exit code 0. Without `--force`, it runs only the suites whose watched paths changed.

    **Summary:** `bun run tev` exited 0 without `--force`. It ran `compile`, `test`, `test:cli:zig`, `test:ziggy`, `test:ziggy:and` and `test:zig` in parallel and every one passed, in 7m 30s. The output is in `tmp/tev-app-log.log`.

## Unit Tests

- None. The only new code is a shell script, and the project rules ban tests for shell scripts. Steps 3 and 4 try it out against a real app instead.

## Smoke Tests

- None added. Steps 3 and 4 run the script against a running Linux app and a running Android app. The walkthrough command changes are prompt text, and they are exercised by the next run of `/test:manual-walkthrough` or `/test:auto-walkthrough`.

## Verify

- `bash -n apps/photosphere/scripts/app-log.sh` exits 0 and `ls -l` shows the executable bit set.
- `mise exec -- bun run app:log` prints usage and exits 2.
- Every check in step 3 passes on Linux.
- Every check in step 4 passes on Android when the pool check reports the pool up at that moment.
- `mise exec -- bun run tev` exits 0.
- The `macos`, `windows` and `ios` branches cannot run on this Linux machine and are not verified here. They first run when the script is used on those platforms.

## Notes

- The log's location comes from Ziggy's `startFileLog` (`core.zig`): the `logs` folder of `$PHOTOSPHERE_LOG_DIR`, otherwise of the data directory each native host gives the core. The data directory paths in step 1 were read from Ziggy's native hosts in `zig-pkg/ziggy-*/packages/ziggy/native/`. Only the Android path (`files/logs`, with `run-as`) has been seen working, during the manual walkthrough of auto-import-existing-remote.
- The story player and the Android smoke tests set `PHOTOSPHERE_LOG_DIR` to a scenario folder (for example `cache/logs-1`), so their logs are not in `files/logs`. The script honours `PHOTOSPHERE_LOG_DIR` for that reason.
- A physical iOS device is not covered. Reading a file from its container needs the lldb session `apps/photosphere-smoke-tests/lib/ios-device.sh` uses. `xcrun devicectl` needs Xcode 15, and the project is locked to Xcode 14.2. The `ios` platform reads only from the simulator. For a physical device, the script fails with a message saying so.
- The script lives in `apps/photosphere/scripts/` beside the other per-app scripts (`reset-android.sh`, `run-android.sh`), because it needs the app's ids. It sources `android-common.sh` only for `adb` and the app id. `photosphere_android_pick_device` is not used, because it can take a device lock.
- `[WARN]` lines do not fail a step on their own, because retries log a `[WARN]` before they succeed. The `[ERROR]` line that follows a retry that runs out is the line that fails the step. This was settled when the plan was written.
- The human answered "No" to a documentation review step, so the documentation is written in step 7 and nothing in the plan stops.
- `test:everything` is run without `--force`, as the project rules require.
- The plan has no Clean up step. The `tmp/app-log-check` folder that step 3 makes is in the gitignored `tmp/`, and the project rules allow `rm -r` only when the human asks for that exact deletion.
