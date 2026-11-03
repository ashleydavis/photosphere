# Type Paths the Way a User Does in the Phone Smoke Tests, and Resolve Short Paths Into the App's Storage

## Overview

On Android and iOS the app's process starts with `/` as its working directory. `createStorage` in `packages-zig/storage-zig/src/lib/storage-factory.zig` resolves a path that has no `fs:` or `s3:` prefix against the working directory (`resolvePath`). So a short name a user types, such as `my-photos` in the Replicate dialog, becomes `/my-photos` and fails with `ReadOnlyFileSystem`. The phone smoke tests never caught this. On a phone they type the full sandbox path that `${PLATFORM}_app_path` prints (`/data/data/au.com.codecapers.photosphere.ziggy/files/<name>` on Android), which no user types or knows. This plan does three things. It makes the core move its working directory to the app's data directory on Android and iOS, so a short name lands in the app's private storage. It changes every phone smoke test step that types a path so the step types the short name a user would. It adds a rule to the global testing rules so a test that stands in for a user always gives the app the input a user gives.

## Issues

## Steps

1. **Move the working directory to the data directory on Android and iOS.** In `packages-zig/photosphere-core/src/lib/main-state.zig`:
    - Add `pub fn enterDataDirectory(io: std.Io, data_dir: []const u8) !void`, with a comment block saying why: a phone starts the app with `/` as its working directory, and every relative path the app is given (a short name typed into New database, Add database, Replicate, Consolidate or Edit origin) is resolved against the working directory by `createStorage`, so the working directory has to be the app's own storage. It asserts that `data_dir` is not empty and is absolute. It creates the directory if it is missing (`std.Io.Dir.cwd().createDirPath(io, data_dir)`, as `single-instance.zig:96` does) and calls `std.process.setCurrentPath(io, data_dir)`, as the test sandboxes in `packages-zig/mobile-worker-zig/src/test/sandbox.zig:101` do. It returns any error to the caller.
    - In `onCreate`, after `services.configureLog(...)` and before `MainState.create(...)`, call `try enterDataDirectory(io, services.dataDir())` only when `builtin.os.tag == .ios or builtin.abi.isAndroid()`, with the same test as `main-state.zig:295`. Log one INFO line with `services.log`: `Working directory set to <data_dir>, so a relative path names a place in the app's own storage.`
    - Desktop builds keep the working directory they are started with. The story player and the desktop smoke tests start the app from the repo root and open the relative path `test/dbs/50-assets` (`packages/user-interface/src/stories/mocks/index.tsx`, `testDatabaseCandidates`).
    - Run `mise exec -- zig build` from the repo root and require exit 0.

2. **Unit test `enterDataDirectory`.** In `packages-zig/photosphere-core/src/test/main-state.test.zig`, add a test with a goal and method comment at the top:
    - It records the current path (`std.process.currentPathAlloc`), makes a temp directory with the temp directory helper the other tests in that file use, and calls `enterDataDirectory` with a path under it that does not exist yet.
    - It asserts that the directory now exists, that `currentPathAlloc` returns it, and that a relative path created through `storage_zig.storage_factory.createStorage(allocator, io, "my-photos", null, null)` has a `normalizedPath` equal to `<data dir>/my-photos`.
    - It sets the current path back to the recorded one with `defer`, as `sandbox.zig:119` does.
    - Run `mise exec -- bun run test:zig 2>&1 | tee tmp/test-zig-typed-paths.log` and require exit 0.

3. **Keep the iOS device smoke test harness working with the new working directory.** `apps/photosphere-smoke-tests/lib/ios-device.sh` gives the app its config, vault and log directories as paths relative to the working directory. It also moves the app into its data container with `chdir` (line 304) before the core is created, because the file log starts before `onCreate` runs. After step 1, `onCreate` moves the working directory again, to the data directory (`<container>/Library/Application Support/au.com.codecapers.photosphere.ziggy`), so the relative config and vault paths would point somewhere else. Make both moves name the same directory:
    - In the `chdir` call at line 304, change the target from `photosphere_ios_device_container "$test_dir"` to `"$(photosphere_ios_device_container "$test_dir")/Library/Application Support/$IOS_DEVICE_BUNDLE_ID"`.
    - In `photosphere_ios_device_pump_log` (line 325), build `logs_dir` from that same data directory instead of the container root.
    - Change the header comment (lines 13 and 14) to say that the run moves the app into its data directory, the directory the core itself moves into on iOS, and gives the settings, vault and log directory as paths relative to it.
    - `photosphere_ios_device_scenario_dir` stays `Library/photosphere-smoke/<name>`, which is now relative to the data directory.
    - Run `bash -n apps/photosphere-smoke-tests/lib/ios-device.sh` and require exit 0.

4. **Type the short name in every phone smoke test step that types a path.** In each test below, in the `android|ios` case only, give the `type` command the short name a user types, not the `${PLATFORM}_app_path` value. Keep the `${PLATFORM}_app_path` value for everything the test does from outside the app, which a user does not do: seeding with `create_database` or `${PLATFORM}_seed_*`, `open-database` and `pick-answer` control commands, and checks of files on the device. Desktop cases stay as they are: they type the full path a desktop user types or picks with Browse. Where the variable is set outside a `case`, add a second variable, set to the short name on `android|ios` and to the existing value otherwise, and type that one. Each test, what it types on a phone and what is expected:
    - `2-create-database/test.sh:37`: type `test-db` into `database-path-input`. Expected: the database is created at `$("${PLATFORM}_app_path" "test-db")` and every existing check passes.
    - `6-add-database-entry/test.sh:54`: type `test-db`. Expected: the entry is added and opens the database seeded at `$("${PLATFORM}_app_path" "test-db")`.
    - `8-share-database/test.sh:40`: type `$DB_NAME`. Expected: the shared entry carries the path as typed and the receiver gets it.
    - `10-view-database/test.sh:66`: type `test-db`. Expected: the View Database dialog shows the path as typed, `test-db`. Change the check that compares the displayed path to compare it with `test-db` on a phone.
    - `17-replicate-database/test.sh:64`: type `source-db`. Lines 94 and 167: type `dest-partial` and `dest-full`. Line 114: type `dest-second`. Expected: the replicas are made at `$("${PLATFORM}_app_path" "dest-partial")` and `$("${PLATFORM}_app_path" "dest-full")`. The file checks at lines 121 to 142 and 189, and the `open-database` commands at lines 151 and 198, keep the full paths. The origin check at line 137 compares the recorded origin with the source path as typed, `source-db`, on a phone.
    - `22-edit-database-origin/test.sh:49`: type `test-db`. Expected: the origin is edited on the entry that was added.
    - `36-consolidate-database/test.sh:82`: type `remote-db` into `consolidate-remote-path-input`. Expected: consolidation reaches the database at `$REMOTE_APP_PATH`. The check at line 111 compares the recorded origin with what was typed, `remote-db`, on a phone.
    - `37-reset-device/test.sh:99` and `:114`: type `test-db`. Expected: the database entry is added and the reset removes it as before. `create_database "$DATABASE_PATH"` at line 86 keeps the full path.
    - `39-reset-device-failure/test.sh:43`: type `test-db` on a phone. Expected: as before.
    - `45-s3-share-replica-sync/test.sh:213`: type `$REPLICA_NAME` on a phone. Expected: the replica is made at `$REPLICA_PATH`. The log wait at line 309 waits for `Starting load for database: "<what was typed>"`.
    - `55-existing-remote-auto-import/test.sh:255`: type `$DB_NAME` on a phone. Expected: the partial replica is made at `$DB_PATH`. The seeding at lines 306 to 311 keeps `$DB_PATH`.
    - `56-large-asset-push/test.sh:191`: type `$REPLICA_NAME` on a phone. Expected: the replica is made at `$("${PLATFORM}_app_path" "$REPLICA_NAME")`. Lines 212 and 229 keep the full path.
    - `64-prefetch-database/test.sh:46` and `:64`: type `source-db` and `dest-partial` on a phone. Expected: the prefetch runs on the replica at `$("${PLATFORM}_app_path" "dest-partial")`. Line 72 keeps the full path.
    - For each test, read every later check that compares a stored or displayed path with the typed variable. Make it compare with the value the app records for what was typed, read from the app's log or config in that test's run. Never widen a check to accept either value.
    - Run `bash -n` over every changed `test.sh` and require exit 0.

5. **Check the unit tests for the same mistake.** The replicate unit tests in `packages-zig/node-api-zig/src/test/replicate-database.test.zig` (lines 40, 68 and 174) call `replicateDatabase` directly with temp paths. They do not stand in for a user typing into the app, so they do not change. The user-facing case, a short name resolved against the app's storage, is covered by the step 2 unit test and the step 4 smoke tests. Record in this step's summary which unit test files were read and why none stood in for a user.

6. **Add the rule to the global testing rules.** In `~/agent-config/rules/testing.md`, add one bullet after "Never fake a test.": "A test that stands in for a user gives the app exactly what a user gives it: the text a user types, the file a user picks, the button a user taps. Never give it a value only the test can know, such as a full sandbox path, because a test that skips the user's path cannot catch a bug on it." This file is in the agent-config repository, which the human asked this plan to change.

7. **Run the tests.** From the repo root, all in parallel:
    - `mise exec -- bun run test:zig 2>&1 | tee tmp/test-zig-typed-paths.log`.
    - At this point, run `mise exec -- bun run emu:and:pool:status -- --quiet`. When it exits 0, run each changed scenario on Android: `PHOTOSPHERE_SMOKE_SCENARIO=<number> mise exec -- bun run test:ziggy:and 2>&1 | tee tmp/ziggy-and-<number>.log` for 2, 6, 8, 10, 17, 22, 36, 37, 39, 45, 55, 56 and 64. Every run must exit 0. When it exits 1, record in this step that the pool was down.
    - Then run `mise exec -- bun run tev 2>&1 | tee tmp/tev-typed-paths.log` in the background and require exit 0. It runs without `--force`, so it runs only the suites whose watched paths changed, including the host Photosphere App suite, because `main-state.zig` changed.

8. **Write the documentation.**
    - In `docs/photosphere-on-ziggy.md`, in the **Startup and shutdown** paragraph, add: on Android and iOS, `onCreate` moves the process's working directory to the app's data directory before the state is made, because a phone starts the app in `/` and every relative path the user types is resolved against the working directory. A short name such as `my-photos` therefore names a folder in the app's private storage. Desktop builds keep the directory they are started in.
    - In `apps/photosphere-smoke-tests/lib/ios-device.md`, change line 7 to match the header comment written in step 3.
    - In `apps/photosphere-smoke-tests/README.md`, or the smoke test guide it links to for writing a scenario, add one sentence: a step that types into the app types what a user types (a short name on a phone), and `${PLATFORM}_app_path` is only for what the test does from outside the app.

## Unit Tests

- `packages-zig/photosphere-core/src/test/main-state.test.zig`: `enterDataDirectory` creates the directory, makes it the current path, and makes `createStorage` resolve `my-photos` to `<data dir>/my-photos` (step 2).

## Smoke Tests

- Phone runs of scenarios 2, 6, 8, 10, 17, 22, 36, 37, 39, 45, 55, 56 and 64 type the short name a user types (step 4). Scenarios 17, 45, 55, 56 and 64 cover the Replicate dialog, the path that failed in the manual test auto-import-existing-remote.

## Verify

- `mise exec -- zig build` exits 0.
- `mise exec -- bun run test:zig` exits 0, including the new `enterDataDirectory` test.
- Every changed scenario passes on Android when the pool check reports the pool up at that moment.
- `mise exec -- bun run tev` exits 0.
- `bash -n` passes on every changed shell file.
- CI-only: `bun run test:ziggy:ios` (needs macOS). The iOS device harness change in step 3 needs a Mac with a connected iPhone and cannot run on this machine or in CI. It is unverified.

## Notes

- Cause, read from the code and the app log: the Replicate dialog passes the typed path unchanged (`replicate-database-dialog.tsx:132`). `replicateDatabaseHandler` passes it to `openStorage` and `createStorage`, which resolves it against the working directory. The log header shows `Working Directory: /` on Android. The iOS device harness comment (`ios-device.sh:13`) records that iOS also starts an app in `/`.
- The human said that resolving any name against `/` is a bug to fix, so the plan includes the fix in step 1.
- The fix sets the working directory once, in `onCreate`, rather than passing a base directory to every `createStorage` call (there are callers in several packages and in the CLI, whose relative paths are correctly resolved against the shell's folder). A relative path stays relative in the app's config, so an iOS update that moves the app's container does not break the stored path.
- Desktop: the human was asked whether desktop smoke tests keep typing full paths (option 1) or answer the Browse picker (option 2), and replied "Try 3, if that works good. Otherwise 2.", then "I meant the first two options." This plan reads that as: desktop keeps the full path a desktop user types (option 1), and Browse is the fallback where a typed full path does not work. Desktop smoke tests do not change.
- The human answered "No" to a documentation review step, so the documentation is written in step 8.
- `test:everything` is run without `--force`.
