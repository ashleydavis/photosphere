# Config reload: Ziggy watches the config and state files and tells the app when they change

## Decisions not approved by a human

- Ziggy finds a change by reading both files on a one-second timer on the core's main thread and comparing the text with what it read last, not by an OS file-change notification.
- The timer runs on every platform, phones included, so a phone's main thread wakes once a second.
- Each file read for the check is limited to 1 MiB, and a larger file is reported as an error.
- The frontend gets two system events, `config-changed` and `state-changed`, each carrying the whole new file as a JSON object.
- `window.ziggy` gains `onConfigChange`, `removeConfigChangeListener`, `onStateChange` and `removeStateChangeListener`.
- The backend gets two optional `ziggy.core.App` fields, `on_config_change` and `on_state_change`, called on the main thread.
- A change this instance writes itself also sends the event, at once on the main thread and within a second when a task wrote it.
- A config or state file that cannot be read on a reload keeps the last good settings and is reported, and no event is sent (see Open questions).
- The test app shows each event in a new `config-log` area, and a new smoke scenario `28-config-reload` edits both files while the app runs.
- The scenario's check on a connected iPhone or iPad ends early with success, as `26-log-files` does, because the host cannot write the app's files there.
- Photosphere reacts to config changes only: the sync, developer and search contexts read their settings again. Its state readers are left as they are.
- Photosphere's config store (`IConfig`) gains `onChange`, and `createConfig` takes a third argument that subscribes to changes.
- Photosphere takes the local Ziggy's TypeScript types through `"ziggy": "file:../../../ziggy/packages/ziggy/frontend"` in `apps/photosphere-frontend/package.json`.
- Photosphere's smoke scenario `24-sync-settings` gains a step that edits the config file while the app runs.
- The example repositories are not changed by this plan.
- Photosphere's `docs/photosphere-on-ziggy.md` gains one sentence saying settings follow edits to the config file.

## Open questions

1. **What happens when the config or state file cannot be read on a reload?** The feature list says what happens at start-up (start with the defaults, or an empty state, and say so). It does not say what happens when a running app finds an unreadable file, such as a config file saved halfway through an edit with a typo in it.
    - Option A: keep the settings the app already has, report the error the same way an unreadable file is reported at start-up (which line is wrong and why), send no change event and do not overwrite the file. When the file is fixed, the next check loads it and sends the event.
    - Option B: switch to the defaults (or an empty state) as start-up does, report the error and send the change event with the defaults.
    - Recommendation: A. A typo while editing would otherwise reset every setting in every open window until the file is saved again. Step 2 is written for A. For B, step 2's "unreadable" branch replaces the main thread's copy with the defaults and sends the event.

## Overview

Ziggy keeps the app's config file (TOML, what the user chose) and state file (JSON, what the app remembers on this computer), as `plan-config-and-state.md` adds them. This plan makes Ziggy notice when either file changes on disk, whoever changed it: the user in an editor, another instance of the app (see `plan-new-window.md`) or this instance. Ziggy then loads the file again into the main thread's copy and sends the app an event: a system event to the frontend carrying the new contents, and a call of the app's backend callback. It works the same on Linux, Windows, macOS, Android and iOS because the check is Zig code in the core, run on the main thread's own timer, and needs no native code.

The work covers the `ziggy` repository (the core, the injected script, the frontend types, the test app, a smoke scenario and the docs) and the `photosphere` repository (the config store and the three contexts that hold settings, and a smoke step). The example repositories need nothing: they lock Ziggy to a release tag, and this plan adds calls they do not have to use. Moving them to the release that contains it is release work, outside this plan.

### Depends on plan-config-and-state.md

This plan runs after `plan-config-and-state.md` is implemented, in the same checkouts. It uses these parts of that plan's code, by the names that plan gives them (read them in the code before step 2):

- The absolute paths of the config file and the state file, which the main thread works out at start-up, and null for a core built for no app (Ziggy's own tests, whose `RegisteredApp.name` is null).
- The main thread's copy of the config and of the state, which the frontend's, the backend's and the menu handlers' reads come from.
- The function that parses config file text (TOML) into that copy and reports which line is wrong and why, and the one that parses state file text (JSON).
- How an unreadable file is reported at start-up.
- The JSON value of the whole config and of the whole state, as the frontend reads them.
- The main thread's function that writes a config or state change (read again, change, write a temporary file, rename).
- The per-scenario config and state directories the smoke test libraries give the app, and the helper (if any) that places a file there.

Where this plan names one of these, it means the one that plan made.

## Issues

## Steps

### Ziggy repository

All paths are under `../ziggy`. Before changing anything, check the pre-commit hook is installed as Ziggy's `CLAUDE.md` says.

1. Add the watch: `packages/ziggy/core/src/lib/config-watch.zig`, with its tests in `packages/ziggy/core/src/test/config-watch.test.zig`, imported from a `test { _ = @import("../test/config-watch.test.zig"); }` block at the bottom of the file (match how `remote-control.zig` reaches its test file). Export it from `packages/ziggy/core/src/index.zig` as `pub const config_watch = @import("lib/config-watch.zig");` beside `remote_control` (line 18).
    - The file's top comment: it finds out whether the config file or the state file changed since it last looked, by reading each and comparing the text with the text it kept. It keeps no Io and no allocator; each function is given the main thread's.
    - `pub const poll_interval_ms: u64 = 1000;` with a comment: a person who saves the file and switches back to the app takes longer than this, and two small reads a second cost little.
    - `pub const file_size_max: u32 = 1024 * 1024;` with a comment: a config or state file holds a few kilobytes, and a larger one is reported rather than read.
    - `pub const WatchedFile = enum { config, state };`
    - `pub const FileText = union(enum) { missing, text: []u8 }`: what the file held when it was last read. A missing file is its own case, because a missing config file means the defaults.
    - `pub const ConfigWatch = struct { config_path: []const u8, state_path: []const u8, config_text: FileText, state_text: FileText }`. The paths are borrowed from the main thread's config and state (they live as long as the main thread). `init(config_path, state_path, config_text, state_text)` takes the texts the main thread read at start-up, so the first check reports no change. `deinit(self, allocator)` frees the kept texts.
    - `pub fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !FileText`: `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(file_size_max))`. `error.FileNotFound` gives `.missing`. `error.StreamTooLong` is returned as `error.FileTooLarge`. Every other error is returned. Assert the result is shorter than `file_size_max`.
    - `pub fn check(self: *ConfigWatch, io: std.Io, allocator: std.mem.Allocator, file: WatchedFile) !?FileText`: reads the file with `readFile`, compares it with the kept text (both missing, or equal bytes, is no change, and the new read is freed and null is returned). On a change it frees the kept text, keeps the new one and returns it (borrowed from the watch, valid until the next check of that file). A read error is returned and the kept text is left as it was, so the next check compares against the last good read.
    - `pub fn remember(self: *ConfigWatch, allocator: std.mem.Allocator, file: WatchedFile, text: []const u8) !void`: replaces the kept text with a copy of `text`. The main thread calls it after this instance writes the file, so the next check does not report its own write a second time.
    - Tests (`std.testing.allocator`, files in `std.testing.tmpDir`), each with a description at the top: no change when the file is unchanged; a change when bytes differ but the size is the same (proves the check does not rely on the size or the modification time); missing to present and present to missing are changes; missing to missing is not; a file over `file_size_max` gives `error.FileTooLarge` and keeps the last text; a read error keeps the last text, so the next good read with the old bytes is no change; `remember` stops the next check reporting that text; a file written through a symlink (stow) is seen through the link (skip creating the link on Windows only where `symLink` returns `error.AccessDenied`, failing on any other error); `std.testing.checkAllAllocationFailures` over `check`.
    - `mise exec -C ../ziggy -- zig build test --summary all` passes.

2. Run the watch on the main thread and send the events: `packages/ziggy/core/src/lib/core.zig`.
    - In `mainThread`, after the config and state are loaded at start-up (by `plan-config-and-state.md`'s code) and when the main thread has their paths, make `var config_watch: config_watch_lib.ConfigWatch` with the texts it read and `defer config_watch.deinit(allocator)`. When the paths are null (a core built for no app), make no watch and set no timer.
    - Add a struct `ConfigPoll` in `core.zig` holding pointers to what the check needs: the watch, the main thread's config and state copies, `frontend` and `app`. In the `start_failure` block (lines 1043 to 1057), before `on_create`, set the timer with `timers.setInterval(io, .{ .context = &config_poll, .function = ConfigPoll.run }, config_watch_lib.poll_interval_ms)` and `break :failed err` on an error, so a timer that cannot be set fails the start through `reportStartFailure`, as an `on_create` error does. `timer_list.clearAll()` at the stop (line 1093) clears it.
    - `ConfigPoll.run(context, io, allocator, timers, services)`: calls `reloadIfChanged` for `.config` then `.state`.
    - `fn reloadIfChanged(poll: *ConfigPoll, io, allocator, services: HandlerServices, timers, file: WatchedFile) void`:
        - `check` returns null: nothing.
        - `check` returns an error, or the new text does not parse (the parse function `plan-config-and-state.md` made): keep the main thread's copy, report it the way start-up reports an unreadable file, with the path, the line and the reason, and also write it to `services.log` as an error. Send no event. (Open question 1, option A.)
        - Otherwise replace the main thread's copy with the parsed one (a missing config file gives the defaults, a missing state file an empty state), then call `sendChange`.
    - `fn sendChange(frontend, app, services, timers, io, allocator, file: WatchedFile, value_json: []const u8) void`: delivers `{"kind":"system","name":"config-changed","data":<the whole config as JSON>}` (or `"state-changed"` with the whole state) with `frontend.deliver`, then calls `app.on_config_change` or `app.on_state_change` when set, with an arena that is freed after the call.
    - The main thread's write function from `plan-config-and-state.md`: after a successful rename, call `config_watch.remember(allocator, file, <the text written>)` and then `sendChange` for that file, so a change this instance makes is announced at once and once. A task that writes the file on a worker is seen by the next check.
    - Add a `test` in `packages/ziggy/core/src/test/main-thread.test.zig`, with an app whose `on_config_change` sends the app event `{"backend":"config-changed"}`, started with `FakeNativeApp` and the config and state paths in a `std.testing.tmpDir` (set the way `plan-config-and-state.md`'s own main-thread tests set them): write a config file, then `expectMessageContaining` the `config-changed` system event with the new value and the app event; write the state file and expect `state-changed`; write an unreadable config file, wait for two poll intervals and expect no second `config-changed` and the error report; write a good file again and expect `config-changed`.
    - `mise exec -C ../ziggy -- zig build test --summary all` passes.

3. Let the app register the backend callbacks: `packages/ziggy/core/src/lib/app.zig`.
    - `RegisteredApp`: add `on_config_change: ?OnConfigChange = null` and `on_state_change: ?OnStateChange = null` after `on_task_event` (line 64), each with a comment: called on the main thread after the file changed and the main thread's copy was loaded again, so the app reads its settings again; the frontend has already been sent the event.
    - Add `pub const OnConfigChange = *const fn (services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator) void;` and `OnStateChange` of the same type, each with a comment, beside `OnTaskEvent`.
    - `app_fields`: add `on_config_change` and `on_state_change`, not required. The compile error text at the `isAppField` check (the list of field names) names both. `App`'s return value sets both with `@hasField`, as `on_task_event` is.
    - Export both types from `core.zig` beside `DestroyPhase` (line 61), with comments pointing at app.zig.
    - Add tests to `packages/ziggy/core/src/test/app.test.zig`: an app that gives both fields has them in its `RegisteredApp`; one that leaves them out has null.
    - `mise exec -C ../ziggy -- zig build test --summary all` passes.

4. The frontend side: `packages/ziggy/core/src/lib/ziggy-inject.js` and `packages/ziggy/frontend/src/ziggy-bridge.ts`.
    - `ziggy-inject.js`: beside `var testCommand = systemEvent("test-command");` add `var configChange = systemEvent("config-changed");` and `var stateChange = systemEvent("state-changed");`, and add `onConfigChange: configChange.on`, `removeConfigChangeListener: configChange.remove`, `onStateChange: stateChange.on` and `removeStateChangeListener: stateChange.remove` to the frozen `window.ziggy` object. Add the two events to the list of system events in the comment at the top of the file.
    - `ziggy-bridge.ts`: add the four methods to `IZiggyBridge` after `removeCoreErrorListener` (line 270), each with a comment. `onConfigChange(callback: IMessageCallback<IJsonObject>): void`: called with the whole config each time the config file changes, whoever changed it. `onStateChange` likewise with the whole state.
    - `packages/ziggy/frontend/src/test/ziggy-inject.test.ts`: add `["config-changed", "onConfigChange", "removeConfigChangeListener"]` and `["state-changed", "onStateChange", "removeStateChangeListener"]` to the table of system events near line 460, and the four names to the list of `window.ziggy` keys near line 536. Add a test: a `config-changed` system event reaches the `onConfigChange` callback with its data, and an app event of the same name does not.
    - `mise exec -C ../ziggy -- bun run compile` and `mise exec -C ../ziggy -- bun run test` pass.

5. The test app shows the events: `apps/ziggy-test-app`.
    - `backend/src/lib/handlers.zig`: add `pub fn onConfigChange(services, timers, io, allocator) void` that sends the app event `{"type":"config-changed-backend"}` with `services.sendEvent`, panicking with a message naming the event on out of memory as the other observers there do, and `onStateChange` sending `{"type":"state-changed-backend"}`. Register both in `backend/src/app.zig` as `.on_config_change` and `.on_state_change`.
    - `backend/src/test/handlers.test.zig`: a test for each that calls it with the test services the file already uses and checks the event text.
    - `frontend/index.html`: a section "Config and state" with `<pre data-id="config-log"></pre>`, before the "Output" section.
    - `frontend/src/main.ts` in `listenForEvents`: `window.ziggy.onConfigChange(config => appendTo("config-log", `config-changed ${JSON.stringify(config)}`))`, the same for `onStateChange` with `state-changed`, and in the app event listener the two backend events appended as `config-changed-backend` and `state-changed-backend`.
    - `mise exec -C ../ziggy -- bun run compile`, `mise exec -C ../ziggy -- bun run test` and `mise exec -C ../ziggy -- zig build test --summary all` pass.

6. Smoke scenario `smoke-tests/28-config-reload/test.sh` (runs on every platform). Use the helper `plan-config-and-state.md` added to the platform libraries to place a file in the scenario's config or state directory. If it added none, add `ziggy_platform_put_config_file <test_dir> <host_file> <config|state>` to `smoke-tests/lib/linux.sh`, `windows.sh`, `macos.sh`, `android.sh` (write through `ziggy_adb exec-in run-as "$ANDROID_APP_ID" sh -c 'cat > <path>'`), `ios.sh` (the simulator's data container, as `ziggy_platform_data_dir` finds it) and `ios-device.sh` (returns 1, because the host has no write access to the app's files on a connected iPhone or iPad), each writing to the path that plan's per-scenario directories give, and document it in the interface comment at the top of `lib/common.sh`.
    - The scenario: `start_test_app`; write a config file setting one key the test app's config holds (from `plan-config-and-state.md`) to `"first"`; `wait_for_text config-log "first"` and `wait_for_text config-log "config-changed-backend"`; write it again with the same size and `"later"` in place of `"first"` (proves a same-size change is seen) and wait for `"later"`; write a state file with a new key and wait for `state-changed` and `state-changed-backend`; write a config file with a TOML syntax error and wait for the error report where the app shows it (as that plan's start-up test reads it), then check with `expect_text_absent` that no `config-changed` after `"later"` arrived; write a good file and wait for it. When the put function returns 1 (a connected iPhone or iPad), end with `exit 0`, as `26-log-files` does when it cannot read the data directory.
    - `bash -n` over every edited script. `mise exec -C ../ziggy -- bun run test:smoke` passes on Linux, with the output written to `../ziggy/tmp/`.

### Photosphere repository

All paths are under `../photosphere`. Before changing anything, check the pre-commit hook is installed as Photosphere's `CLAUDE.md` says. Photosphere takes the local Ziggy: Zig through `--fork=../ziggy`, and the TypeScript types by setting `"ziggy"` in `apps/photosphere-frontend/package.json` to `"file:../../../ziggy/packages/ziggy/frontend"` (unless `plan-config-and-state.md` already set it) and running `mise exec -C ../photosphere -- bun install`.

7. The config store announces changes: `packages/user-interface/src/context/config-store-context.tsx`.
    - `IConfig`: add `onChange(callback: () => void): Unsubscribe` with a comment: called each time the stored settings change, whoever changed them, so a reader reads its keys again. Import `Unsubscribe` from where `platform-context.tsx` defines it.
    - `createConfig(getRaw, setRaw, subscribe: (callback: () => void) => Unsubscribe)`: `onChange` returns `subscribe(callback)`.
    - `packages/user-interface/src/stories/mocks/index.tsx` (line 465): pass a `subscribe` that keeps the callbacks in a `Set` and returns a function removing it; the mock's `setRaw` calls each callback after it stores the value, so stories behave like the app.
    - Add `packages/user-interface/src/test/context/config-store-context.test.ts` (check the directory layout `src/test` already uses and mirror it): `onChange` passes the callback to `subscribe` and returns what it returns.

8. Photosphere's frontend feeds it: `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx`, at the `createConfig` calls (lines 983 and 1000, as `plan-config-and-state.md` left them).
    - Config: `callback => { const listener = () => callback(); ziggy.onConfigChange(listener); return () => ziggy.removeConfigChangeListener(listener); }`.
    - State: the same with `onStateChange` and `removeStateChangeListener`.
    - `apps/photosphere-frontend/src/test/fake-ziggy.ts`: add the four methods to `FakeZiggy`, keeping the listeners as it keeps the core error listeners (lines 102 to 106), and a method the tests call to send a `config-changed` or `state-changed` event to them.

9. The contexts that hold settings read them again on a change.
    - `packages/user-interface/src/context/sync-context.tsx` (lines 95 to 109), `developer-context.tsx` (lines 149 to 163, the two config reads only, not the `state.get` of the developer tools) and `search-context.tsx` (line 95, `savedSearches` only): move each effect's reads into one function in the effect, call it once, register it with `config.onChange` and return the unsubscribe as the effect's clean-up. A key that is now undefined sets the value the context starts with (sync and Wi-Fi-only: their `useState` initial values; developer mode and the FPS indicator: false; saved searches: `[]`), so removing a key from the file takes effect.
    - No new unit tests for these React contexts (Photosphere's `CLAUDE.md`); the smoke step below covers the sync context.

10. Smoke step: `apps/photosphere-smoke-tests/24-sync-settings/test.sh`, after the last toggle and before `check_no_errors`.
    - Read the config file with `read_config_file`, set the sync section's enabled key to false (in the TOML layout `plan-config-and-state.md` gave the sync settings, and with `sed` on that one line), write it to a file in `$TMP_DIR` and put it back with `put_config_file`. Then `wait_for_log "$TMP_DIR" "Sync gate set to false"`: the sync context read the setting again and pushed its decision.
    - Comment above the step: the file is edited from outside the running app, the way a user edits it, and the app follows without a restart.

11. Photosphere checks, from `../photosphere`, each run's output written to `tmp/`:
    - `mise exec -- bun run compile` and `mise exec -- bun run test` pass.
    - `mise exec -- zig build test --fork=../ziggy --summary all --test-timeout 20m` passes.
    - The Linux app smoke tests against the local Ziggy:
        1. `env -C apps/photosphere mise exec -- bun run bundle:ui --out-dir "$(pwd)/tmp/local-ziggy/page"`
        2. `mise exec -- zig build photosphere-linux --fork=../ziggy -Dcpu=baseline -Doptimize=ReleaseSafe -Dstrip=false -Dui-directory=tmp/local-ziggy/page --prefix "$(pwd)/tmp/local-ziggy/linux"`
        3. `mise exec -- zig build --fork=../ziggy -p "$(pwd)/tmp/local-ziggy/psi"`
        4. `PHOTOSPHERE_SMOKE_BUILD="$(pwd)/tmp/local-ziggy/linux" PHOTOSPHERE_SMOKE_PSI="$(pwd)/tmp/local-ziggy/psi/bin/psi" PHOTOSPHERE_SMOKE_SCENARIO=24 mise exec -- bun run test:ziggy`, then the same without `PHOTOSPHERE_SMOKE_SCENARIO` for the whole suite.

### Documentation

12. Write the documentation. Ziggy paths are under `../ziggy` and Photosphere paths under `../photosphere`:
    - The user guide page `plan-config-and-state.md` adds for config and state: a section "When the files change". Ziggy reads both files once a second and compares them with what it read last. On a change it loads the file again, sends `config-changed` or `state-changed` to the frontend (`onConfigChange`, `onStateChange`, each given the whole file as a JSON object) and calls `on_config_change` or `on_state_change`. A change the app makes itself is announced too. An unreadable file keeps the current settings and is reported with its line and reason.
    - `docs/user-guide/app-declaration.md`: the `on_config_change` and `on_state_change` fields, beside `on_task_event`.
    - `docs/development/architecture.md`: the main thread's poll timer among the main thread's work, and the two system events beside the others.
    - `docs/upgrade-notes.md`, under the next version: "**`window.ziggy` has `onConfigChange`, `removeConfigChangeListener`, `onStateChange` and `removeStateChangeListener`.** A fake of `IZiggyBridge` in the app's tests adds the four." and "**New, and optional:** `on_config_change` and `on_state_change` in `ziggy.core.App`."
    - Photosphere: `docs/photosphere-on-ziggy.md` gains one sentence where it describes config and state (as `plan-config-and-state.md` left it): the settings follow edits to the config file while the app runs, through the config store's `onChange`.
    - No doc, comment or script references this plan.

## Unit Tests

- `packages/ziggy/core/src/test/config-watch.test.zig`: every case in step 1, for `readFile`, `check` and `remember`.
- `packages/ziggy/core/src/test/main-thread.test.zig`: the reload test in step 2, covering `ConfigPoll.run`, `reloadIfChanged` and `sendChange`.
- `packages/ziggy/core/src/test/app.test.zig`: the two fields in step 3.
- `packages/ziggy/frontend/src/test/ziggy-inject.test.ts`: the listener pairs and the routing test in step 4.
- Test app `backend/src/test/handlers.test.zig`: `onConfigChange` and `onStateChange`.
- Photosphere `packages/user-interface/src/test/.../config-store-context.test.ts`: `createConfig`'s `onChange`.
- The React contexts in step 9 and `platform-provider-ziggy.tsx` are covered by the Photosphere smoke step, as Photosphere's `CLAUDE.md` requires.

## Smoke Tests

- Ziggy `smoke-tests/28-config-reload`: an external edit of the config file and of the state file reaches the frontend and the backend; a same-size edit is seen; an unreadable file keeps the settings and is reported; a fixed file is loaded.
- Photosphere `24-sync-settings`: an external edit of the sync setting reaches the sync context, which pushes the new decision.

## Verify

- Ziggy, from `../ziggy`, output written to `tmp/`: `mise exec -- zig build test --summary all`, `mise exec -- bun run compile`, `mise exec -- bun run test` and `mise exec -- bun run test:smoke` exit 0.
- Ziggy Android: run `adb devices` at this point. When a serial is in state `device`, `mise exec -C ../ziggy -- bun run test:smoke:android` and `mise exec -C ../ziggy -- bun run test:zig:android` exit 0. When none is, both are CI-only.
- Ziggy iOS and macOS (`test:smoke:ios`, `test:zig:ios`, the macOS smoke tests) and Windows smoke tests: CI-only on a Linux machine.
- Photosphere: every check in step 11 exits 0.
- Photosphere `bun run test:ziggy:and`: CI-only, because `apps/photosphere/scripts/sync-android.sh` builds Ziggy's Android native app from the git tag in `build.zig.zon` with no fork option.
- `bash -n` passes over every edited shell script.
- `grep -rn "plan-config-reload" ../ziggy ../photosphere` over `*.md`, `*.ts`, `*.tsx`, `*.zig` and `*.sh`, excluding `docs/plans` and `node_modules`, prints nothing.

## Notes

- The documentation is written in the last step and the plan has no review stop: the human answered "No" to a documentation review.
- The example repositories (`ziggy-example-vite`, `ziggy-example-rsbuild`) need no change: they lock Ziggy to a release tag, and this plan adds only optional calls. Moving them to the release that holds it is release work.
- Polling, not OS notifications: an editor or the atomic update saves by renaming a new file over the old one, which ends an inotify or kqueue watch on the old file, and stow makes the config file a symlink. Reading the path each time follows the link and survives the rename, needs no native code on any platform and keeps the work on the main thread at its own pace (`general.md`: no direct reaction to external events).
- The check compares the text, not the modification time: macOS's HFS+ and FAT keep times to a second or two, so two saves inside that time would look the same.
- On Windows, Zig 0.16 opens files with read, write and delete sharing (`Io/Threaded.zig`, `dirOpenFileWindows` passes `.VALID_FLAGS`), so another instance's rename over the file succeeds while this instance is reading it.
- No thread shares state: the timer, the watch, the copies and the callbacks are all on the main thread. A task's own write is not announced at once because the task runs on a worker; the next check finds it.
- Photosphere's automatic import already reads its settings on every tick of its own check (`ensure-auto-import`, `main-process.zig`), so its backend needs no `on_config_change`.
- Theme changes are `plan-theme.md`'s; it may build its theme event on `on_config_change`. Starting another instance is `plan-new-window.md`'s; this plan makes every instance follow the others' writes.
- Changing `apps/photosphere-frontend/package.json` to a `file:` path is for building against the local Ziggy. Setting it back to a release tag is release work, outside this plan.
- The plan deletes nothing, so it has no Clean up step, and it has no Release step.
