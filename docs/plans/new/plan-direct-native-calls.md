# Answer desktop native calls directly instead of through JSON messages

## Overview

Photosphere's background tasks run on Ziggy worker threads and reach the platform through `callNativeApp` (`packages-zig/photosphere-core/src/lib/background-work.zig`). It sends the method name and a JSON request to the main thread, which hands them to the native app. The native app replies with JSON text, and the task parses that text back.

On a phone that trip is needed, because the answer comes from Java or Swift. On a desktop it is waste:

- **`requestNotificationPermission`** and **`networkConnectionType`** always give the same answer on a desktop (`{"granted":true}` and `"unknown"`). Yet:
  - Linux sends a message to its Zig native app (`apps/photosphere/native/linux/src/main.zig`) to get them.
  - Windows and MacOS build a `WindowsNativeCalls`/`MacosNativeCalls`, pick the answer by comparing method names as strings, return JSON text, and the caller parses it again.
- **`backgroundLog`** on a desktop only prints a line. Linux sends it to the native app to print, and Windows and MacOS route it through the same string dispatch with a JSON encode and parse.
- **`holdAwake`** on Windows and MacOS must cross to the main thread, which owns the power request. But the task wraps a JSON request inside the event, `main-process.zig` stringifies that request again, and `main-state.zig` hands it to the string dispatch, which parses it a third time.

This plan has desktops answer the constant calls and the log on the task's own thread with plain Zig calls. The Windows and MacOS hold travels as a plain boolean in its event. Every phone path stays exactly as it is. On Linux, `holdAwake` stays a native call, because the hold belongs to the GTK main thread.

## Issues

## Steps

1. **A shared phone check** (`packages-zig/photosphere-core/src/lib/background-work.zig`).
   - Add `pub const is_phone = builtin.os.tag == .ios or builtin.abi.isAndroid();` with a comment: the calls only a phone's native app can answer go through `callNativeApp`, and a desktop answers them itself.
   - Make the code compile with `mise exec -- zig build test -Dtest-file=photosphere-core/mobile-requests.test.zig -Dcli-test-file=none --summary all`.

2. **Notification permission** (`packages-zig/photosphere-core/src/lib/mobile-requests.zig`, `startBackgroundImportHandler`).
   - Add `pub fn readNotificationPermission(allocator: std.mem.Allocator, reply: []const u8) !bool`. It parses the reply and returns `granted`. It throws "The phone's answer to requestNotificationPermission could not be read." when the reply is not JSON, not an object, or has no boolean `granted`, the same message the handler throws today.
   - In the handler:
     - when `background_work.is_phone`, call `callNativeApp(..., "requestNotificationPermission", "null")` and pass the reply to `readNotificationPermission`;
     - otherwise take `granted` as `true` with no call.
     - Keep the "Notifications were refused" log line for `false`.
   - Compile and run the mobile-requests tests (see Unit Tests).

3. **Connection type** (`packages-zig/photosphere-core/src/lib/mobile-planning.zig`, `networkConnectionTypeOfTask`).
   - Add `pub fn readNetworkConnectionType(allocator: std.mem.Allocator, reply: []const u8) ![]const u8`. It holds the parse and the two errors from today's function, worded exactly as now:
     - "The phone's answer to networkConnectionType could not be read."
     - "The phone's answer to networkConnectionType was not text."
   - In `networkConnectionTypeOfTask`: when `background_work.is_phone`, make the native call and pass the reply to `readNetworkConnectionType`. Otherwise return `"unknown"` with no call.
   - Update the function's comment, which today says Windows makes the call itself.
   - Compile and run the mobile-planning tests.

4. **Background log** (`background-work.zig`, `sendBackgroundLog`).
   - When not `is_phone`, write `message` with `utils.console.@"error"(message)` and return. That is the line the Windows and MacOS dispatch wrote, and the Linux native app wrote it to standard error too.
   - Keep the JSON request and `callNativeApp` for phones.
   - Compile and run the photosphere-core tests named under Unit Tests.

5. **Hold awake event** (`background-work.zig`, `holdAwakeOfTask`, `HOLD_AWAKE_EVENT_TYPE`; `main-process.zig` hold-awake branch; `main-state.zig`, `holdAwake`).
   - **`holdAwakeOfTask`:** when `builtin.os.tag` is `.windows` or `.macos`, send the event directly with `services.sendEvent(io, allocator, .{ .type = HOLD_AWAKE_EVENT_TYPE, .awake = awake })`. On every other platform, keep the `callNativeApp(..., "holdAwake", ...)` call.
   - **`HOLD_AWAKE_EVENT_TYPE`:** change its comment to say the event carries `awake`, a boolean.
   - **`main-process.zig`:** read `awake` from the event object. When it is missing or not a boolean, throw "A request to hold the computer awake has no awake flag." Call `main_state.current().holdAwake(awake)`.
   - **`MainState.holdAwake`:** change it to `pub fn holdAwake(self: *MainState, awake: bool) !void`. It calls `self.windows_native_calls.holdAwake(awake)` or `self.macos_native_calls.holdAwake(awake)`, and keeps the error for other platforms.
   - Compile for the host and run `mise exec -- zig build photosphere-windows-check -Dcompile-only=true -Dtarget=x86_64-windows-gnu`, the Windows compile check used in this worktree.

6. **Remove the string dispatch** (`packages-zig/photosphere-core/src/lib/windows-native-calls.zig`, `macos-native-calls.zig`, `background-work.zig`).
   - In both native-calls files:
     - delete `call`, `IHoldAwake` and `IBackgroundLog`, and make `holdAwake` `pub`;
     - change the struct comment to say it holds the computer awake for the main thread.
   - In `background-work.zig`:
     - delete `callOnDesktop` and its comment;
     - in `callNativeApp`, replace the `error.NativeCallMissing` branch with `return utils.errors.throwError("{s} is only available in the Photosphere app on a phone.", .{method});`;
     - remove the `windows_native_calls` and `macos_native_calls` imports if nothing else in the file uses them.
   - Compile for the host and run the Windows compile check from step 5.

7. **Linux native app** (`apps/photosphere/native/linux/src/main.zig`, `nativeCall`).
   - Delete the `requestNotificationPermission`, `networkConnectionType` and `backgroundLog` branches and the `IBackgroundLog` struct. Keep `holdAwake` and the final `return null`.
   - Rewrite the function comment to say it handles `holdAwake`, which needs the GTK main thread.
   - Build the Linux app with `mise exec -- bun run build:ziggy:linux`. Run `mise exec -- bun run bundle:ui` in `apps/photosphere` first if the build reports the UI `dist` missing.

8. **Tests.** Update the tests listed under Unit Tests, and run each changed test file until it passes.

9. **Documentation** (`docs/zig-json.md`).
   - Rewrite the "The native Linux app" section to say the Linux native app answers only `holdAwake`, and parses its request with `std.json.parseFromSlice`.
   - Add one sentence under Writing JSON: JSON is for text that crosses a thread or process boundary. A call that stays on one thread passes Zig values.

## Unit Tests

- **`mobile-requests.test.zig`.** These tests ran the phone path on the Linux host, where the core now answers itself. Their phone-path assertions move to the pure functions, with the same messages.
  - Replace "startBackgroundImport asks the phone for the notification permission first, and fails with the reason when it cannot" with:
    - `readNotificationPermission` returns `true` for `{"granted":true}` and `false` for `{"granted":false}`.
    - A phone's error reply still reaches the user with its reason. "a request the phone could not do is an error reply with the reason it gave" already covers that path through `callNativeApp`.
  - Replace "startBackgroundImport refuses a notification answer it cannot read" with: `readNotificationPermission` throws "The phone's answer to requestNotificationPermission could not be read." for `{"allowed":true}` and for `not json`.
  - Rename "on Windows and MacOS, whose shells have no host request callback, the core starts and stops the background work itself" to "on a desktop the core starts and stops the background work itself, without asking the native app". Delete its non-Windows, non-MacOS early branch, so every desktop runs the start and stop assertions. Add `try std.testing.expect((try app.lastNativeCall(calls.allocator())) == null);` after the start.
  - Keep "on a platform with no host request callback every request says it is only available on a phone": its message now comes from `callNativeApp` directly.
- **`mobile-planning.test.zig`.** Replace "plan-sync asks the phone for the connection type when syncing is switched on, and a phone that cannot answer is an error that says so" with three tests:
  - `readNetworkConnectionType` returns `wifi` for `"wifi"`.
  - `readNetworkConnectionType` throws "could not be read." for `not json`.
  - `readNetworkConnectionType` throws "was not text." for `3`.
  - "plan-sync on a desktop does not ask the native app for the connection type": the same config setup as the test it replaces, then `lastNativeCall` is null once the task ends. The expected end status is the one `plan-sync.worker.zig` gives for an allowed connection with that config; read it from that file.
- **`windows-native-calls.test.zig` and `macos-native-calls.test.zig`.**
  - Delete the tests whose subject is gone: the notification permission, the connection type, the background report and the unreadable report, the unknown method, and the unreadable hold.
  - Change the nested-holds test to call `holdAwake(true)`/`holdAwake(false)` directly, with the same assertions, including the non-Windows (non-MacOS) error branch and message.
- **`background-work`.** For `holdAwakeOfTask` on Windows and MacOS, add a test in the existing background work test file (find it with `grep -ln holdAwake packages-zig/photosphere-core/src/test`). It sends the event with `awake` and makes no native call, and it runs only where `builtin.os.tag` is `.windows` or `.macos`. On the Linux host it asserts that the hold still goes to the native app as `holdAwake`, using the `TestApp` native call recorder (`lastNativeCall`).
- **`main-process`.** Add a test of the hold-awake event with a missing `awake`: it throws "A request to hold the computer awake has no awake flag." Use the main-process test file found with `grep -ln HOLD_AWAKE packages-zig/photosphere-core/src/test`. If none exists, use the test file that already sends task events to `main-process.zig`.

## Smoke Tests

- `bun run test:ziggy` exercises the Linux desktop app, including background passes that take and release the hold through the native app.
- `bun run test:ziggy:and` exercises the phone path, which keeps sending all four calls to the Java native app.

## Verify

- Run each test file named above with `mise exec -- zig build test -Dtest-file=photosphere-core/<file> -Dcli-test-file=none --summary all`. Every step in the Build Summary succeeds and no test fails.
- The Windows compile check from step 5 succeeds.
- `mise exec -- bun run build:ziggy:linux` succeeds.
- `mise exec -- bun run test:everything` exits 0 (no `--force`).
- `grep -rn 'callOnDesktop\|fn call(' packages-zig/photosphere-core/src/lib` finds nothing.
- `grep -n 'requestNotificationPermission\|networkConnectionType\|backgroundLog' apps/photosphere/native/linux/src/main.zig` finds nothing.
- The MacOS build runs only on a Mac and is CI-only. The macOS changes mirror the Windows ones and compile under the host build of `macos-native-calls.zig`, which the unit tests import.

## Notes

- **Phone paths are unchanged.** Android and iOS still answer all four calls in `PhotosphereNativeCalls.java` and `PhotosphereNativeCalls.swift`. Calling those APIs directly from Zig would need AI-written JNI and Objective-C runtime bindings, and the Android permission prompt must run on the UI thread anyway, so this plan leaves phones on messages.
- **What stays a message.** The Linux `holdAwake` and the Windows and MacOS hold event both stay messages. They cross from a worker thread to the main thread, and the project rule makes JSON messages the only thing that crosses threads.
- **Which tests change.** The phone-path tests in `mobile-requests.test.zig` and `mobile-planning.test.zig` ran on the Linux host through the fake native call. Once the Linux host is a desktop that answers itself, those paths do not run on the host. Their reply-reading assertions move, unchanged in wording, to `readNotificationPermission` and `readNetworkConnectionType`, and on-device coverage stays with `test:ziggy:and`.
- **How desktop and phone are told apart.** `is_phone` uses the same `builtin` test the core already uses in `main-state.zig`, `main-process.zig` and `config-and-state.zig`. No runtime flag or test-only switch is added.
- **`backgroundLog` keeps its behaviour.** On a desktop it keeps writing to standard error, which is what all three desktops did before.
