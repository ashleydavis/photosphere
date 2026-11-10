# Remote control: target a window by number

## Decisions not approved by a human

- A window that disconnects frees its number, and the next app to connect takes the lowest free number.
- The remote control server does all of the work, and the app's core and native apps are not changed.
- The list command is `{"command":"windows"}`, answered by the server as `{"ok":true,"value":[1,2]}` and never sent to an app.
- The server takes the `window` field off a line before it sends the line to the app.
- A line with no `window` and a line that is not a JSON object both go to window 1 unchanged.
- A `window` that is not a whole number from 1 to the window limit gets `{"ok":false,"error":"InvalidWindow"}` at once.
- A line for a window that has not connected waits for it the way a line waits for an app today, then gets `AppNotConnected`.
- The server accepts at most 100 apps at once and closes any app past that.
- A new app connection no longer replaces the connected app, so `restart_test_app` waits until the server lists no windows before it starts the app again.
- The server keeps one script connection at a time, as it does today.
- The test starts the second app as a process of its own, in a scenario that runs on Linux, Windows and macOS only.
- The new smoke test is scenario `28-window-targeting` in `smoke-tests/desktop-only`.
- The test app's smoke library gains `list_windows`, `wait_for_windows`, `window_control` and an optional window argument to `wait_for_ready`, and the template's smoke library does not change.
- Photosphere and both example repositories are not changed by this plan.
- `docs/upgrade-notes.md` gets a line under a new `## v0.0.24` heading.

## Open questions

1. **What number does an app get after a window has closed?** The feature list says the server numbers apps "in the order they connect, starting at 1" and does not say what happens to the number of a window that closes. This matters to `restart_test_app` (`smoke-tests/lib/common.sh`, used by `17-ui-storage`), which stops the app and starts it again on the same server, and then sends commands with no `window`.
    - Option A: the next app takes the lowest number no connected app has. The restarted app is window 1 again, and commands with no `window` reach it. Numbers still follow connect order while no window closes.
    - Option B: numbers are never used twice in the server's life. The restarted app is window 2. Every command after a restart then needs `"window": 2`, and a command with no `window` waits for a window 1 that never comes back.
    - Recommendation: A. The rest of this plan is written for A.

## Overview

The remote control server (`tools/remote-control-server` in the Ziggy repository) takes one app connection at a time, and a new app replaces the one before it. A Ziggy app that opens a new window starts a second process (plan-new-window.md), and under remote control that process connects to the same server. This plan lets the server hold many app connections at once, numbers them from 1 in the order they connect, sends each script line to the window its `"window": <n>` field names (window 1 when it has none) and answers `{"command":"windows"}` with the numbers of the connected windows. The change is in the server and in the Ziggy test app's smoke tests and docs. The app's own code does not change: the server takes the `window` field off before the app sees the line.

Dependency: plan-new-window.md needs this plan for its smoke test of a second window. This plan does not need plan-new-window.md: its smoke test starts the second app process itself, the way the test already starts the first. No sibling plan is needed by this one.

## Issues

## Steps

Run every command from the root of the repository it names, through that repository's mise (`mise exec -C <repository> -- <command>`).

### Ziggy repository

1. Read which window a script line is for. New file `tools/remote-control-server/src/lib/script-line.ts`, with a top comment block saying it reads what the server needs from a script line: the window it goes to and whether it is the server's own `windows` command.
    - `export const WINDOW_COUNT_MAX = 100;`, with a comment saying why: a smoke test opens a few windows, so more than this many apps means a test is starting apps in a loop. It limits both the window numbers a line may name and the apps the server holds.
    - `export interface ILineTarget { window: number; text: string; }`: the window the line goes to and the text to send the app. Each field gets a comment block.
    - `export interface IInvalidWindowError { name: "InvalidWindow"; text: string; }`: a line whose `window` is not a whole number from 1 to `WINDOW_COUNT_MAX`, with the line as it came.
    - `export function readTarget(text: string): Result<ILineTarget, IInvalidWindowError>` (using `Result`, `ok` and `err` from `./result`). It parses the line with `JSON.parse` inside `try`/`catch`. A line that does not parse, or parses to something other than a plain object (`null`, an array, a string or a number), is `ok({ window: 1, text })` with the text unchanged, so the app still answers it with `InvalidCommand` (scenario `7-control-reports-bad-commands`). An object without a `window` key is `ok({ window: 1, text })` with the text unchanged, byte for byte. An object with a `window` key that is a whole number (`Number.isInteger`) from 1 to `WINDOW_COUNT_MAX` is `ok({ window, text: JSON.stringify(<the object without its window key>) })`. Any other `window` value (0, a negative number, a fraction, a string, `null`, a number above `WINDOW_COUNT_MAX`) is `err({ name: "InvalidWindow", text })`. Assert that the text has no newline, and that an `ok` window is a whole number from 1 to `WINDOW_COUNT_MAX`.
    - `export function isListWindowsCommand(text: string): boolean`: true when the line parses to a plain object whose `command` is the string `"windows"`, whatever other keys it has. False for a line that does not parse and for any other value. Assert that the text has no newline.
    - New test file `tools/remote-control-server/src/test/lib/script-line.test.ts`, with a description comment at the top, a `describe` for each function and a `test` for each case listed under Unit Tests.
    - `bun run --filter=ziggy-remote-control-server compile` and `bun run --filter=ziggy-remote-control-server test` pass.

2. Hold many apps in the server and route each line to its window. Edit `tools/remote-control-server/src/lib/remote-control-server.ts`. Import `WINDOW_COUNT_MAX`, `isListWindowsCommand` and `readTarget` from `./script-line`.
    - Top comment (lines 76 to 82): the server takes many app connections at once and numbers each with the lowest number from 1 that no connected app has, so numbers follow connect order while no window closes. Each line goes to the window its `window` field names, or window 1 when it has none, with the field taken off. `{"command":"windows"}` is answered by the server.
    - New `export interface IConnectedApp`, each field with a comment block: `window: number` (its number), `socket: WebSocket` (its connection) and `owed: Socket[]` (for each line sent to this app and not yet answered, oldest first, the script connection it came on).
    - `IRelayState` (lines 211 to 232): replace `app` and `owed` with `apps: Map<number, IConnectedApp>`, the connected apps by window number. Update `startRemoteControlServer`'s `state` (lines 254 to 259) to match.
    - `IWaitingLine` (lines 191 to 206): add `window: number`, the window the line waits for. `text` is the text to send that app, with the `window` field already taken off.
    - `IRemoteControlServerOptions.appWaitTimeoutMs` comment (lines 110 to 113): a line waits that long for its window to connect.
    - New `export function lowestFreeWindow(state: IRelayState): number | undefined`: the lowest number from 1 to `WINDOW_COUNT_MAX` that `state.apps` does not hold, or `undefined` when all are held. A loop bounded by `WINDOW_COUNT_MAX`. Assert that the result is not in `state.apps`.
    - New `export function listWindows(state: IRelayState): number[]`: the connected window numbers in ascending order. Assert that the count equals `state.apps.size`.
    - `acceptApp` (lines 394 to 419): stop replacing the connected app. Take `lowestFreeWindow(state)`. When it is `undefined`, `writeError` that more than `WINDOW_COUNT_MAX` apps connected to port `<appPort>` so this one was closed, then `app.terminate()` and return. Otherwise add `{ window, socket: app, owed: [] }` to `state.apps`. The `message`, `close` and `error` handlers pass the window number on, and the error message names it (`The app's connection to the remote control server on port <port> as window <n> failed: ...`). Send every waiting line whose `window` is this one, in order, clearing its timer, and leave the other waiting lines with their timers. Update the comment above it. Assert that the window was free before and is held after.
    - `releaseApp` (lines 425 to 435): `releaseApp(state: IRelayState, window: number, app: WebSocket)`. Return when `state.apps.get(window)?.socket !== app`. Otherwise delete the entry and write `{"ok":false,"error":"AppDisconnected"}` to each script in its `owed`. Update the comment above it.
    - `sendToApp` (lines 440 to 444): `sendToApp(connected: IConnectedApp, script: Socket, text: string)` pushes to `connected.owed` and sends. Assert that the text has no newline.
    - `receiveReply` (lines 450 to 465): takes `window: number` in place of `app`. It shifts the script from that window's `owed`, and the "reply to no line" error names the window. Its last assertion checks that `state.apps.get(window)` is still the app the reply came from.
    - `receiveLine` (lines 530 to 548): when `isListWindowsCommand(text)`, write `JSON.stringify({ ok: true, value: listWindows(state) })` to the script and return. Otherwise call `readTarget(text)`. On `InvalidWindow`, `writeError` that the line's window is not a whole number from 1 to `WINDOW_COUNT_MAX` so it got InvalidWindow (with the line), write `{"ok":false,"error":"InvalidWindow"}` to the script and return. When `state.apps` has the target window, `sendToApp` with the target text. Otherwise keep the existing waiting path, recording `window` and the target text, and keep the `WAITING_LINES_MAX` limit over all windows together. Update the comment above it.
    - `expireLine` (lines 553 to 559): the error names the window: `No app connected to port <appPort> as window <n> within <ms> ms, so this line got AppNotConnected: <text>`.
    - `close` (lines 304 to 318): terminate every app in `state.apps`.
    - Tests in `tools/remote-control-server/src/test/lib/remote-control-server.test.ts`:
        - Rewrite the test "a new app replaces a connected one, whose unanswered line gets AppDisconnected" (lines 331 to 346) as "a second app becomes window 2 while the first stays connected": both apps stay open, a line with no `window` reaches the first app and `{"command":"ready","window":2}` reaches the second as `{"command":"ready"}`.
        - "answers AppNotConnected when no app connects within the wait" (lines 348 to 358): the expected error is the new `expireLine` text with `as window 1`.
        - `connectApp` (lines 187 to 207): reword the comment on its `error` handler (line 191) to say a server that closes or turns away the connection ends it at once.
        - Add a test for each case listed under Unit Tests.
    - `bun run --filter=ziggy-remote-control-server compile` and `bun run --filter=ziggy-remote-control-server test` pass.

3. The Ziggy test app's smoke library, `smoke-tests/lib/common.sh`. The template's `apps/ziggy-template/smoke-tests/lib/common.sh` does not change: it has no restart and no scenario of the template's uses a second window.
    - After `control` (ends line 178), add three functions, each with a comment block that has a usage line:
        - `window_control <window> <json>`: adds the window to the command with `jq -c --argjson window "$1" '. + {window: $window}'` and sends it with `control`, printing the reply. A `jq` failure fails the scenario naming the command.
        - `list_windows`: sends `{"command":"windows"}`, fails the scenario when `.ok` is not `true` and prints `.value` with `jq -c` (for example `[1,2]`).
        - `wait_for_windows <json array>`: polls `list_windows` once a second until it prints the array given, for up to `WAIT_TIMEOUT_SECONDS`, then fails with the array it last printed.
    - `wait_for_ready` (lines 183 to 195): takes an optional window number. With one, it sends `ready` through `window_control`. Update its comment.
    - `restart_test_app` (lines 126 to 132): after `ziggy_platform_stop`, call `open_control_connection` and then `wait_for_windows '[]'`, then `ziggy_platform_start ... keep-data`, then `wait_for_ready`. Drop the second `open_control_connection` after the start. Update the comment above it: the server sees the old connection end only some time after the app has stopped, and a new app connecting before then would be window 2.
    - Update the interface comment at the top of the file only if it mentions a single app connection.
    - `bash -n smoke-tests/lib/common.sh` passes.

4. New scenario `smoke-tests/desktop-only/28-window-targeting/test.sh` (executable, `#!/usr/bin/env bash`). 28 is the next unused number in `smoke-tests` today. When another change has taken it by the time this step runs, use the next unused number, here and in `run.md`. It runs on Linux, Windows and macOS only, because Android and iOS run one instance of an app on a device. Its top comment says it checks that the remote control server numbers windows, sends each command to the window it names and lists the windows, using a second app process the scenario starts itself.
    - Source `../../lib/common.sh`. Set `SECOND_DIR="$ZIGGY_TEST_DIR/second"` and `THIRD_DIR="$ZIGGY_TEST_DIR/third"`, and replace the trap with `trap 'ziggy_platform_stop "$SECOND_DIR" || true; ziggy_platform_stop "$THIRD_DIR" || true; stop_app_on_exit' EXIT`, so the run's leak check finds no app left running.
    - `start_test_app`, then `wait_for_windows '[1]'`.
    - `ziggy_platform_start "$SECOND_DIR" || fail "the second app did not start"`, then `wait_for_windows '[1,2]'` and `wait_for_ready 2`. Each test directory has its own data directory (`XDG_DATA_HOME`, `LOCALAPPDATA` or `HOME` in `lib/linux.sh`, `lib/windows.sh` and `lib/macos.sh`), so the two apps share no data.
    - `window_control 2 '{"command":"click","dataId":"start-short"}'` returns `.ok` true. Poll `window_control 2 '{"command":"get-text","dataId":"output"}'` once a second until `.value` contains `hello from a short task`, for up to `WAIT_TIMEOUT_SECONDS`. Then `expect_text_absent output "hello from a short task"`, which has no window and so reads window 1.
    - `control '{"command":"ready","window":0}'` and `control '{"command":"ready","window":"2"}'` each return `.error` `InvalidWindow`.
    - `ziggy_platform_stop "$ZIGGY_TEST_DIR"`, then `wait_for_windows '[2]'` and `wait_for_ready 2`.
    - `ziggy_platform_start "$THIRD_DIR" || fail "the third app did not start"`, then `wait_for_windows '[1,2]'` and `wait_for_ready`. `text_of output`, with no window, does not contain `hello from a short task`, which shows window 1 is now the third app, and window 2's `get-text` of `output` still contains it.
    - Add the scenario to the `desktop-only` list in `smoke-tests/run.md`, after `25-close-with-dialog-open`: two app processes on one remote control server are windows 1 and 2, a command reaches the window its `window` field names (window 1 when it has none), `windows` lists them and a closed window's number goes to the next app.
    - `bash -n` passes over the scenario.

### Example repositories

5. `ziggy-example-vite` and `ziggy-example-rsbuild`: no change. Each depends on Ziggy and on `ziggy-remote-control-server` at tag `v0.0.23` (`package.json`), each scenario starts one app on its own server, `smoke-tests/lib/common.sh` has no restart and no command sends `window`, so every command goes to window 1 as it does today.

### Photosphere repository

6. Photosphere: no change. It depends on `ziggy-remote-control-server` at tag `v0.0.23` (root `package.json`). `apps/photosphere-smoke-tests/lib/common.sh` starts a server for each app instance (`photosphere_start_remote_control_server`, called from each platform's start), so each server has one app, and no command sends `window`.

### Documentation

7. Write the documentation in the Ziggy repository to match the code.
    - The server's `tools/remote-control-server/README.md`, section "What it does":
        - Replace "One app and one script are connected at a time..." with: many apps can be connected at once, each numbered with the lowest number from 1 that no connected app has, and one script is connected at a time, a new script connection replacing the one before it.
        - Add: a line goes to the window its `"window": <n>` field names, or window 1 when it has none, with the field taken off. A line that is not a JSON object goes to window 1 unchanged.
        - Add: `{"command":"windows"}` is answered by the server with `{"ok":true,"value":[<numbers>]}`, the connected windows in ascending order.
        - Add: a `window` that is not a whole number from 1 to 100 gets `{"ok":false,"error":"InvalidWindow"}`. A line for a window that is not connected waits for it for 90 seconds, then gets `AppNotConnected`. When an app's connection ends, its number is free for the next app.
        - Replace "When the app connection ends, the server waits for the next app, so a scenario that restarts the app keeps the same server" so it says a scenario that restarts the app keeps the same server and waits until `windows` lists no window before it starts the app again.
    - `docs/user-guide/testing.md`, section "The remote control connection": after the paragraph on the remote control server, add a subsection "Several windows". Each app started with the same `--remote-control` address is a window of its own, numbered from 1 in the order it connects, and a closed window's number goes to the next app that connects. A command goes to window `<n>` with `"window": <n>` added, and to window 1 without it. `{"command": "windows"}` returns the connected windows' numbers in `value`. A `window` that is not a whole number from 1 to 100 gets `InvalidWindow`. A scenario that restarts the app on the same server waits until `windows` lists no window first.
    - `docs/development/architecture.md`, section "Remote control" (the bullet on the remote control server, line 164): add that it numbers each connected app as a window and sends each line to the window it names.
    - `docs/glossary.md`: in "Remote control server" (line 31), add that it numbers each app that connects as a window. Add an entry **Window number**: the number from 1 the remote control server gives each app connected to it, which a command names with its `window` field.
    - `docs/upgrade-notes.md`: add a `## v0.0.24` heading at the top of the version list when the file has none, with the line: **A new app connection no longer replaces the connected one on the remote control server.** A smoke test that stops the app and starts it again on the same server waits until `{"command":"windows"}` returns an empty `value` before it starts the app, or the new app is window 2.

## Unit Tests

- `script-line.test.ts`, `readTarget`: a line that is not JSON, a JSON array, a JSON string, a JSON number and `null` are window 1 with the text unchanged; an object without `window` is window 1 with the text unchanged byte for byte (including spacing); `window` 1, 2 and `WINDOW_COUNT_MAX` give that window and the text without the `window` key, other keys in their order; `window` 0, -1, 1.5, `"2"`, `null`, `true` and `WINDOW_COUNT_MAX + 1` are `InvalidWindow` carrying the line.
- `script-line.test.ts`, `isListWindowsCommand`: true for `{"command":"windows"}` and for it with a `window` key; false for another command, for `"windows"` as a JSON string, for an array, for an object without `command` and for a line that is not JSON.
- `remote-control-server.test.ts`:
    - Two apps are windows 1 and 2, and `{"command":"windows"}` gets `{"ok":true,"value":[1,2]}`. No app receives it: the next line, with no `window`, is the first message app 1 receives.
    - A line with `"window":2` reaches app 2 without the `window` key, and app 2's reply reaches the script.
    - Lines to window 1 and to window 2 sent before either replies: app 2 replies first and app 1 second, and the script gets each reply as it is sent, in that order.
    - A line for window 2 sent while only window 1 is connected waits, and app 2 receives it when it connects. App 1 receives nothing.
    - A line for window 2 that no app connects for in time gets `AppNotConnected`, and the error names port, window 2 and the line.
    - `InvalidWindow` for `"window":0` and `"window":"2"`, answered at once, with the error written. No app receives a message.
    - Window 1 disconnects: `windows` gets `[2]`. A new app connects: `windows` gets `[1,2]`, and a line with no `window` reaches the new app.
    - Window 1 goes with a line unanswered: that line gets `AppDisconnected`, and window 2 still relays a line and its reply.
    - With `WINDOW_COUNT_MAX` apps connected, one more app is closed by the server and the error naming the limit and the port is written. `windows` lists every number from 1 to `WINDOW_COUNT_MAX`.
    - `close` ends every connected app.
    - `lowestFreeWindow`: 1 for an empty state, the gap when 1 and 3 are held, `undefined` when every number to `WINDOW_COUNT_MAX` is held.
    - `listWindows`: ascending order whatever order the apps were added in.
    - `acceptApp`, `releaseApp`, `sendToApp`, `receiveReply`, `receiveLine` and `expireLine` are each driven by the server tests above, which start a real server and connect real WebSocket and TCP clients.

## Smoke Tests

- New `smoke-tests/desktop-only/28-window-targeting` on Linux, Windows and macOS.
- `smoke-tests/17-ui-storage`, which calls `restart_test_app`, on every platform, to check the wait for an empty window list.
- Every other scenario of the test app's suite, because `common.sh` changed.

## Verify

- In the Ziggy repository: `bun run --filter=ziggy-remote-control-server compile` and `bun run --filter=ziggy-remote-control-server test` exit 0.
- `bash -n smoke-tests/lib/common.sh` and `bash -n smoke-tests/desktop-only/28-window-targeting/test.sh` exit 0.
- `bun run test:smoke 28-window-targeting`, then `bun run test:smoke 17-ui-storage`, then `bun run test:smoke` (the whole Linux suite) exit 0.
- `bun run test:smoke:android 17-ui-storage`, then `bun run test:smoke:android`, exit 0. This shows the server sees the old connection end after `adb reverse --remove` and `am force-stop`.
- CI-only: the Windows, macOS and iOS smoke jobs of Ziggy's CI workflow.

## Notes

- The app's core (`packages/ziggy/core/src/lib/remote-control.zig`), the native apps and the frontends do not change. The server takes the `window` key off before it sends the line, so the app never sees it, and the app's handling of every command is the same.
- Lines without `window` are sent byte for byte, so every existing scenario and the unit tests that send lines that are not JSON (`first`, `quit`) behave as before. A line that is not a JSON object goes to window 1, so the app still answers it with `InvalidCommand`.
- `windows` is a command name no app or frontend handles (`remote-control.zig` `handleLine`, `apps/ziggy-test-app/frontend/src/lib/test-commands.ts`), so the server can answer it. Its reply uses `value`, as `get-text` does.
- A line for a window that is not connected waits for it with the same timeout and limit as a line waits for window 1 today, so a test can send `"window": 2` straight after the action that opens the window.
- The server stops replacing the connected app with a new one. It replaced the app because a restarted app could connect before the server saw the old connection end. With many windows, a new connection is a new window, so `restart_test_app` waits for `windows` to list no window instead. That is a wait for a state the server reports, not a fixed delay.
- The scenario starts its second and third apps with `ziggy_platform_start` in test directories of their own, so it works before plan-new-window.md is done and stays a test of the server once it is. Each app's processes are recorded through `launch_in_process_group` and stopped by the trap.
- The Linux native app creates its `GtkApplication` with `G_APPLICATION_NON_UNIQUE` (`packages/ziggy/native/linux/src/lib/native-app.zig` line 114), so a second process of the test app runs as a second app.
- Photosphere starts one server for each app instance and sends no `window`, so it needs no change. The example repositories start one app on one server and never restart it, so they need no change. Each takes the new server when it moves to the Ziggy release that contains it, which is outside this plan.
- `WINDOW_COUNT_MAX` limits both the numbers a line may name and the apps the server holds, so every window number a line can name is one an app can have.
- Documentation is written in the last implementation step, with no review stop before implementation.
- The Ziggy repository needs no dependency on Photosphere or the example repositories, and they take nothing from it in this plan, so no local path dependency is needed.
