# Background task smoke tests

Recommended: Ziggy gains a task command on its test control connection and a task test runner with greedy parallel lanes. Each app (Photosphere, the example apps) supplies one JSON file per test plus a small hooks script for setup and disk checks (Option D).

## Where the tasks are

- The Photosphere App (Ziggy) runs the Zig handlers only. Worker tasks are registered in `packages-zig/node-api-zig/src/lib/task-handlers.zig:63`. The core's own tasks are listed in `packages-zig/photosphere-core/src/lib/handlers.zig:93`.
- Both are registered when the core starts (`packages-zig/photosphere-core/src/lib/main-state.zig:211`). The photo library source is registered only on a phone (`main-state.zig:214`).
- The page queues a task by sending `add-task` to the core (`apps/photosphere-frontend/src/lib/ziggy-queue-backend.ts:149`). The core sends `task-message` and `task-completed` back to the page.
- The TypeScript handlers (`packages/node-api/src/lib/task-handlers.ts`, `packages/mobile-worker/mobile-worker-entry.ts`) are run by the Electron app, the TypeScript CLI and the Capacitor mobile apps, not by the Ziggy app. They are left out here and are already reached by `test:electron`, `test:cli`, `test:and` and `test:ios`.
- The tasks behind request channels (`handlers.zig:45`: vault, config, pickers, secure store and the rest) answer a page request and are left out of the list below.
- The `psi` CLI already runs `import-assets`, `hash-file`, `upload-asset`, `check-file`, `verify-file`, `replicate-database`, `consolidate-database` and `cleanup-sources` through its own worker pool (`apps/cli-zig/src/lib/worker-pool.zig`), so `test:cli:zig` covers those on the desktop.

## Option D: task tests provided by Ziggy, driven by JSON files (recommended)

### What Ziggy gains

- Test control commands handled by the core itself, not the page, in the same place `quit`, `menu` and `pick-answer` are handled (`ziggy/packages/ziggy/core/src/lib/test-control.zig:285`): `start-task` (type, data, source, priority, returns the task id at once), `task-status` (status, output, error and the messages sent so far) and `cancel-tasks` (by source). The core already sees every task end and message through the runner's observer (`task-runner.zig`, `TaskRunnerOptions.observer`), so it can keep them per task id. Compiled in only with `-Dtest-hooks`, like the other hooks.
- The runner polls `task-status`, because a command that waits for a task would hit the control connection's limits (30 seconds for a page reply at `test-control.zig:19`, 90 seconds in Photosphere's `control_command` at `apps/photosphere-smoke-tests/lib/common.sh:170`) and import, sync and replicate can take longer.
- A runner script, `run-task-tests.sh [linux|windows|macos|android|ios] [test]`, with a `.md` beside it. With no platform it uses the host, as `run-desktop.sh` does. It builds the app once with the test hooks, finds the JSON files, runs them in greedy lanes (below) and prints passed, skipped and failed.
- Ziggy's smoke test scripts reach apps today by being copied from the template: `ziggy-example-vite/smoke-tests/lib` is a copy that has drifted from `ziggy/smoke-tests/lib`. No way for an app to take shell scripts from a Ziggy package was found, so the runner would be copied the same way or Ziggy would need a way to ship it.

### What the app keeps

- `task-tests/<task-type>/<case>.json`, one file per test. Contents:
  - `taskType`, `data`, `source` and `priority`.
  - Placeholders in `data` for paths and addresses that differ per platform and per test, such as `{dataDir}`, `{testDir}`, `{s3Endpoint}`. A path on Android is inside the app's files directory, not on the host, so literal paths cannot work.
  - `platforms` it runs on, with the reason for any it skips.
  - `timeoutSeconds`.
  - `cancel`: when to cancel (after a message type or after some time), for cancel tests.
  - `expect`: `status` (succeeded, failed, cancelled), parts of the output that must match, text the error must contain, message types that must arrive.
  - `setup` and `check`: names of steps from the app's hooks script, with arguments.
  - `files`: fixtures to copy into the app's data directory before the start.
- `task-tests/hooks.sh`: the named setup and check steps. Photosphere's would wrap helpers it already has: `${PLATFORM}_seed_database`, `put_config_file`, `start_s3_emulator`, the photo library helpers, `fetch_app_database` and `run_zig_cli` (`verify`, `summary`, `compare`).
- The task handlers are unchanged.

### How a result is checked

- Covered by the JSON file alone: status, output values, error text, messages, cancel and timeouts. That is enough for `test-job`, `check-database-exists`, `get-database-summary` (counts as expected output), `get-import-record`, `load-assets` (message counts) and every "invalid data" or "is required" failure.
- Needs a check step in the app's hooks script: anything read from disk (`psi verify`, `summary`, `compare` after import, replicate, sync, move, consolidate, evict, cleanup, reset), the asset server's HTTP answers and the LAN share tasks, which need `psi` running as the other side.
- The background pass tasks always return null (`packages-zig/photosphere-core/src/lib/background-work.zig:704`), so their JSON can only say "succeeded"; the check step does the real work.
- Needs a setup step: seeded databases, the S3 emulator, the photo library, config files.
- `hash-file`, `upload-asset`, `check-file` and `verify-file` take input their parent normally builds. A JSON file can hold that input written out by hand against a fixed fixture database, with placeholders for paths. Whether a hand-written `verify-file` tree node stays valid as the fixture changes was not checked.

### Parallel lanes

- A lane is one place a test can run: one app instance on a desktop, one device on Android, one simulator on iOS. Each lane takes the next waiting test as soon as it is free.
- Photosphere already has this: the rolling pool in `scripts/lib/test-pool.sh` (refills a slot the moment its test ends), the lane width from `resolve_test_parallel` in `scripts/lib/test-concurrency.sh`, the device cap `photosphere_platform_device_limit` and the per-device lock (`android_claim_device` in `apps/photosphere-smoke-tests/lib/android.sh:184`), all used by `apps/photosphere-smoke-tests/run.sh`. `scripts/test-everything-parallel.sh` would run the new suite as one more lane beside the others.
- Ziggy's own `smoke-tests/run.sh` runs scenarios one after another. It has a per-device lock for Android (`ZIGGY_ANDROID_DEVICES`) but no pool, so the pool would be ported into Ziggy.
- Desktop: many lanes. Each test gets its own temp directory (`scripts/lib/allocate-test-temp-dir.sh`), its own settings, vault and log directories (`PHOTOSPHERE_CONFIG_DIR`, `PHOTOSPHERE_VAULT_DIR`, `PHOTOSPHERE_LOG_DIR`), its own `LOCALAPPDATA` on Windows and `HOME` on macOS. Ports the operating system chooses (control port, asset server, MCP server in test mode, S3 emulator) keep tests apart.
- Android: one lane per device that can reach the host, because the app id is fixed and one device holds one copy of the app. The app is installed once per device and its data cleared between tests (`reset_app_state`).
- iOS: one lane. `apps/photosphere-smoke-tests/lib/ios.sh:107` uses one simulator and one copy of the app. Using several simulators was not checked.

### One test per app instance, not many tests in one

- Many tests inside one running app would share its settings, vault, default database and main process state (one automatic import, one sync, the pass timers), so one test's setup changes another's result.
- Each app has a fixed number of worker threads (`TaskRunnerOptions.worker_threads`, `task-runner.zig:97`). The asset server, the MCP server and keep-alive passes hold one each for as long as they run. A parent waiting for its children needs more. `docs/mobile-background-tasks.md` describes the old engine pool hanging when it ran out; this was not checked for Ziggy's runner.
- Every test would need its own `source` so cancelling one does not cancel another. One crash would fail every test in that app.
- So: one test per app start, many app starts in parallel lanes. On a phone the install is reused and only the data is cleared.

### Compared with the other options

- Against A: the same idea, but the commands live in Ziggy's core, not in Photosphere's page, so no test-only code is added to the app and the example apps get it too. Core-handled commands do not go through the page; whether they keep working while an Android app is in the background was not checked. Costs more: a runner, a pool and the commands in Ziggy, plus the placeholder and hooks scheme.
- Against B and C: B cannot reach most cases from the UI and C runs on the desktop only.
- Most of the Photosphere tests listed below still need a check step from the app's hooks script, so "almost automatic" holds for the running, waiting and simple checks, not for checking what was written to disk.

## Option A: test commands in Photosphere's page, new script on the existing runner

- Add `start-task`, `task-status` and `cancel-tasks` to the page's test driver in `apps/photosphere-frontend` (next to `installTestDriver` at `src/main.tsx:89`). Add a `run-tasks.sh [platform]` that runs `apps/photosphere-smoke-tests/run.sh` on a `tasks/<n>-<name>/test.sh` folder. `run.sh` lists scenarios from a fixed folder (`run.sh:74`) and records a fixed what-changed baseline, so both would become arguments.
- Each test is a shell script using the existing helpers and gets the same pool, device claiming and isolation as the current suite.
- Good: smallest change, all in Photosphere.
- Bad: test-only code in the app, which `CLAUDE.md` says needs the human's approval. Photosphere only. The commands go through the page, which can be suspended when an Android app is in the background (`49-background-import/test.sh:9`).

## Option B: more scenarios in the existing suite, through the UI

- Add scenarios to `apps/photosphere-smoke-tests` that reach each task by clicking, as `62-sync`, `63-database-summary`, `64-prefetch-database`, `33-import-cancel`, `17-replicate-database`, `18-move-file` and `36-consolidate-database` do now.
- Good: no new test hooks. It tests what a user does.
- Bad: many cases cannot be reached from the UI (bad input, cancel at a chosen point, child tasks). Results are read from the screen, not from the task. No separate script for background tasks.

## Option C: a headless Zig program that runs one task

- A small program that registers the handlers and runs one task from JSON, the way the CLI worker pool or `packages-zig/photosphere-core/src/test/test-support.zig` (core on a stand-in shell) do.
- Good: fast, no window, no device. Easy to feed edge cases.
- Bad: desktop only. Phone-only shell requests (photo library, keychain, background log) would be stand-ins, which is what the Zig unit tests (`test:zig`) already do. Whether such a program could run on a phone through `adb shell` or `xcrun simctl spawn` was not checked.

## Tests per task

Under Option D each line is one JSON file. Where a line says "(check)", the expected result was not confirmed in the code and must be read from the handler before writing the test.

### Worker tasks (`node-api-zig`)

- `test-job`: runs for `durationMs`, sends `job-progress` messages through each stage and succeeds.
- `test-job`: cancelled part way, ends early as cancelled.
- `test-job`: invalid data fails with the "task data is not valid" message.
- `create-database`: new local path succeeds and `psi verify` passes on the result.
- `create-database`: missing `databasePath` fails with "databasePath is required".
- `create-database`: S3 path against the local MinIO succeeds (check).
- `create-default-database`: creates the database and records it as the default and in the database list.
- `create-default-database`: run when the default database already exists (check).
- `check-database-exists`: a database gives `exists: true`.
- `check-database-exists`: an empty directory gives `exists: false`.
- `check-database-exists`: a path that does not exist (check).
- `get-database-summary`: fixture database gives the same counts as `psi summary`.
- `get-database-summary`: empty database gives zero counts (check).
- `get-database-summary`: missing `databasePath` fails.
- `load-assets`: streamed batches add up to every asset in the fixture.
- `load-assets`: on a partial replica it also queues `prefetch-database`.
- `load-assets`: cancelled part way stops streaming.
- `get-import-record`: after an import lists the imported files.
- `get-import-record`: a new database gives an empty record (check).
- `set-database-origin`: sets the origin and `psi origin` shows it.
- `set-database-origin`: `origin: null` clears it (check).
- `set-database-origin`: missing `databasePath` fails.
- `import-assets`: a folder of photos and a video lands in the database and `psi verify` passes.
- `import-assets`: the same files again add nothing new.
- `import-assets`: `dryRun: true` writes nothing.
- `import-assets`: a damaged image is reported as failed and the rest are imported (check).
- `import-assets`: cancelled part way stops. An import after it completes (the failure `33-import-cancel` found).
- `hash-file`: a valid file gives the same hash as `psi hash`.
- `hash-file`: a damaged image fails with "Failed to validate and hash file".
- `upload-asset`: a hashed file is stored and shows in the database.
- `check-file`: a file already imported is reported as imported, a new one is not.
- `verify-file`: an untouched file passes, a changed file is reported as modified, a deleted file as missing (check).
- `save-asset`: writes the asset to `destPath` with the stored bytes.
- `save-asset`: unknown `assetId` fails (check).
- `save-assets-batch`: writes every asset to the folder.
- `save-assets-batch`: invalid data fails with the "task data is not valid" message.
- `move-assets`: the assets leave the source and appear in the destination. Both pass `psi verify`.
- `move-assets`: an unknown asset id fails with "Asset ... not found in source database".
- `replicate-database`: local to local, `psi compare` finds no differences.
- `replicate-database`: local to S3 on the local MinIO.
- `replicate-database`: cancelled part way ends as cancelled.
- `sync-database`: no origin returns `synced: false`.
- `sync-database`: an origin that cannot be reached returns `synced: false`.
- `sync-database`: changes on both sides end up on both sides.
- `prefetch-database`: a partial replica gets its missing thumbnails and index files.
- `prefetch-database`: a full database returns at once with nothing fetched.
- `prefetch-database`: an encrypted partial replica (as `59-prefetch-encrypted-replica`).
- `prefetch-database`: cancelled part way ends as cancelled.
- `consolidate-database`: a local database is joined to a remote that has content. Both pass `psi verify`.
- `consolidate-database`: a remote path with no database fails with "There is no database at".
- `consolidate-database`: missing `remotePath` fails with "remotePath is required".
- `evict-originals`: over budget, originals are dropped (check what is kept).
- `evict-originals`: under budget, nothing is dropped.
- `evict-originals`: cancelled part way ends as cancelled.
- `cleanup-sources`: `dryRun: true` deletes nothing.
- `cleanup-sources`: no sources configured fails with "no sources configured".
- `cleanup-sources`: deletes the source photos the database already holds and keeps the rest.
- `reset-app-storage`: desktop empties config and cache and keeps the data directory.
- `reset-app-storage`: phone clears the data directory too (the core's version, `config-and-state.zig:218`).
- `asset-server`: sends `asset-server-ready` with a port. `GET /asset` returns the stored bytes of a fixture asset.
- `asset-server`: `POST /apply-database-ops` applies an edit that `psi` can then read.
- `asset-server`: cancelled, the port stops answering.
- `receive-share`: receives a payload sent by `psi`.
- `receive-share`: times out or is cancelled and returns null.
- `find-receiver` with `send-payload`: finds a `psi` receiver and delivers the payload.
- `find-receiver`: no receiver, returns null on timeout or cancel.

### Core tasks (`photosphere-core`)

- `read-config` with `write-config`: write the automatic import section, read it back, other sections unchanged.
- `plan-auto-import`: automatic import switched off gives a plan that stops (check).
- `plan-auto-import`: switched on with a library gives import steps (check).
- `plan-sync`: no origin and with an origin (check the plan for each).
- `plan-prefetch`: full database and partial replica (check the plan for each).
- `ensure-auto-import`: config switched on starts an import into the default database.
- `ensure-auto-import`: config switched off starts nothing.
- `check-for-news`: a feed served by the test through `PHOTOSPHERE_NEWS_URL` gives a news item.
- `check-for-news`: a feed that cannot be reached ends without taking the app down.
- `mcp-server`: desktop only, a tool call through the server (already in `60-mcp-server`).
- `background-auto-import`: one pass with a seeded library imports the new photos.
- `background-sync`: one pass pushes a local change to the origin.
- `background-prefetch`: one pass fills a partial replica.
- Each of the three passes: switched off in the config, the pass changes nothing.

## Things that block or complicate it (verified)

- No test command can start a task today. Ziggy's core handles only `quit`, `menu`, `screenshot`, `drop` and `pick-answer` itself and the page's test driver handles UI actions only (`packages/user-interface/src/lib/test-driver.ts:553`), so Option A or D needs new commands.
- A pass started by hand also sets when the timer runs the next pass (`background-work.zig:698`), so it changes the timing of the app's own background work during the test.
- iOS: the system decides when a `BGProcessingTask` runs and a test cannot force one (`apps/photosphere-smoke-tests/49-background-import/test.sh:19`). Starting the pass task by a test command runs its code on iOS but not the system's trigger.
- iOS: the simulator cannot remove a seeded photo (`35-auto-import/test.sh:29`). `lib/ios.sh` has none of the per-test photo library helpers that `lib/android.sh` and `lib/linux.sh` have, so import from the photo library and `cleanup-sources` can only be tested on Android and the desktop.
- The photo library source exists only on a phone (`main-state.zig:214`). The desktop imports from a folder instead.
- `mcp-server` runs on the desktop only and its scenario skips phones (`60-mcp-server`).
- `check-for-update` always calls GitHub (`packages-zig/photosphere-core/src/lib/update-and-news.zig:29`) and test mode skips it at start, so it has no local test and is left out.
- `sync-database` does not check for cancel, so it has no cancel test.
