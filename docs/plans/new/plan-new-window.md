# New window: start another instance of the app

## Decisions not approved by a human

- The frontend starts a new window with a new `window.ziggy.newWindow(arguments)`, and the backend with a new `HandlerServices.newWindow`, rather than a new standard action.
- The core builds the new instance's arguments and the native app starts the process, through a new `new-window` call to the native app, as `quit` and `screenshot` are done.
- The core refuses an app argument `--remote-control` with `error.RemoteControlArgument`, because the core adds that option itself.
- A new `has_new_window` flag in `ziggy_config` is true on Linux, Windows and macOS and false on Android, iOS and in dev mode, where `newWindow` fails with `error.NewWindowUnavailable`.
- Android and iOS get no new window: each runs one process per app with one core, so a window that is a process of its own cannot exist there.
- Linux and Windows start the process with Zig's `std.process.spawn`, from a new shared core file `new-instance.zig`; macOS calls the same code through a new C function `ziggy_start_instance`.
- Linux reaps each new instance with GLib's `g_child_watch_add`, and macOS with a `DispatchSource` process source and `waitpid`.
- The new-window call returns the new process id, and the core writes the line `Started a new window, process <pid>.` to the app's log.
- The app's log file names gain the process id (`<prefix>-<time>-<pid>.log`), because two instances started in the same second wrote the same file.
- The Linux smoke libraries (the test app's and the template's) start Xvfb as a process of its own instead of through `xvfb-run`, because `xvfb-run` ends the display when its first window exits.
- The template and the test app each gain a `new-window` action, "New Window", `CmdOrCtrl+N`, on the File menu.
- The test app's action passes `-geometry=640x480`, so the smoke test can see that the new window got its arguments.
- The new smoke scenario is `smoke-tests/desktop-only/29-new-window`, after the `28-window-targeting` scenario of plan-remote-control-window-targeting.md.
- This plan is carried out after plan-remote-control-window-targeting.md, whose server and smoke helpers its scenario uses.
- Photosphere gets no New window action. It only takes the new interface members in its test fakes, built against the local Ziggy with `zig build --fork`.
- The example repositories are not changed by this plan.
- The upgrade notes go under a `## v0.0.24` heading.

## Open questions

1. **How does a Windows smoke test end every window?** In the feature list the new instance stays in its parent's process group, so a test that ends the group ends every window. That holds on Linux and macOS: Zig's spawn leaves the process group alone when `pgid` is null (`std/Io/Threaded.zig` line 15004), and a forked or `posix_spawn`ed process keeps its parent's group. Windows has no process groups. Under Git Bash, `launch_in_process_group` falls back to the launched pid (`smoke-tests/lib/process-control.sh`, `process_control_verify_job_control`), and `kill_process_group` reaches only the processes Git Bash itself started. The new window is started by the app with `CreateProcessW`, so Git Bash does not know it and the Windows harness leaves it running after the scenario.
    - Option A: the core writes `Started a new window, process <pid>.` (the Windows process id) to the app's log for every new window. `ziggy_platform_stop` in `smoke-tests/lib/windows.sh` reads those lines from every log file in the scenario's data directory and ends each process with `taskkill //F //PID <pid>`. The log line is useful to a user too, so it is not a test hook.
    - Option B: the app sends its process id to the remote control server when it connects, the server lists it with each window, and `ziggy_platform_stop` ends each listed window by its process id. This changes the remote control protocol owned by plan-remote-control-window-targeting.md.
    - Option C: the Windows scenario quits each window through the remote control connection and the harness ends only the first window, as today. A failed scenario then leaves windows running on the machine.
    - Recommendation: A. The rest of this plan is written for A.

## Overview

An app needs an action, such as Graft's File > New Window (`CmdOrCtrl+N`), that starts another instance of itself with arguments it chooses. Each instance is a separate process with one window and its own backend and task queue, closing one never ends the others, and an instance started under remote control passes the same `--remote-control <host:port>` on so it connects to the same remote control server and stays in its parent's process group. This plan adds `window.ziggy.newWindow(arguments)` and `HandlerServices.newWindow`, a `new-window` call to the native app, the code that starts the process on Linux, Windows and macOS, a "New Window" action in the template and the test app, process ids in the log file names and a smoke scenario that opens, uses and closes a second window. The design was checked against each platform. Linux fits: the GTK application is already `G_APPLICATION_NON_UNIQUE`, so a second process opens its own window. Windows fits, with the process-group gap in Open question 1. macOS fits when the app's executable inside its bundle is started directly: each process has its own menu bar and Dock icon, and `applicationShouldTerminateAfterLastWindowClosed` ends only that process. Starting it through Launch Services (`open -n`) is rejected, because launchd then starts it and it leaves the parent's process group. Android and iOS do not fit: each app runs one process holding one core, a second Android task or iPad scene would share that process and its backend, so `newWindow` fails with `NewWindowUnavailable` there. Dev mode, whose frontend is a browser tab, has no new window either.

## Issues

## Steps

Run every command through the repository's mise: `mise exec -C <repository> -- <command>`. The repositories are `~/projects/photosphere/ziggy`, `~/projects/photosphere/photosphere`, `~/projects/photosphere/ziggy-example-vite` and `~/projects/photosphere/ziggy-example-rsbuild`. plan-remote-control-window-targeting.md is implemented first: its `{"command":"windows"}` server command and its `list_windows`, `wait_for_windows`, `window_control` and `wait_for_ready <window>` helpers in `smoke-tests/lib/common.sh` exist before step 9.

### Ziggy repository

1. Give each instance's log files their own names. `packages/ziggy/log/src/lib/file-log.zig`, `FileLog.start` (lines 84 to 128):
    - The file names become `<file_prefix>-<start time>-<process id>.log` and `<file_prefix>-<start time>-<process id>-errors.log`. Two instances started in the same second wrote and truncated the same file, because `writeFile` creates the file afresh and the start time has whole seconds only.
    - The process id is `std.c.getpid()` (the log package links libc, `build.zig` line 169) on every target but Windows, and `std.os.windows.GetCurrentProcessId()` on Windows. Assert it is above 0.
    - Update the comment on `file_prefix` (line 42) and the comment above `start`.
    - `packages/ziggy/log/src/test/file-log.test.zig` (line 100): the expected name is `test-app-<timestamp>-<process id>.log`. Build the expected suffix from the process id the test reads the same way and assert the name ends with it, and keep the length check with the process id's digits added.
    - `zig build test` passes.

2. The new-window call. `packages/ziggy/core/src/lib/native-message.zig`:
    - `Call` gains `new_window: []const []const u8`: start another instance of the app with these arguments after the program's name. The result is the JSON text of the new process's id, a number.
    - `Wire` gains `arguments: ?[]const []const u8 = null`. `encode` sets it for `.new_window`, `parse` reads `"new-window"` and fails with `error.InvalidCall` when `arguments` is missing, and `typeName` gives `"new-window"`.
    - `packages/ziggy/core/src/lib/ziggy.h`: add the line `{"type":"new-window","arguments":["..."]}` to the list of calls (after `screenshot`, line 93): start another instance of the app, as a process of its own, with the arguments; the result is the new process's id as a JSON number. Add the field `bool has_new_window;` after `has_screenshot`, with the comment "Whether the native app does "new-window" calls: starts another instance of the app."
    - `packages/ziggy/core/src/lib/types.zig`, `ZiggyConfig`: add `has_new_window: bool` after `has_screenshot`, in the same place as in `ziggy.h`, with the same comment.
    - Every literal of `ZiggyConfig` gets the field: `core/src/lib/jni.zig` (line 338, `.has_new_window = false`, with a comment that an Android app runs one process with one core), `core/src/lib/fake-native-app.zig` `config` (line 158, `.has_new_window = true`). Every native app that zeroes the struct leaves it false: the dev host (`dev/src/lib/dev-host.zig` line 480) and iOS (`native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift` line 182).
    - Every exhaustive switch over `Call` handles `.new_window`: `jni.zig` line 504 adds it to the calls the Android app never gets, `fake-native-app.zig` `handleCall` (line 676) records it like the others, and `defaultResult` gives `"4242"` (a process id that the test can recognise) unless the test set another result for `new-window`.
    - No test covers `native_message` today and `core/src/index.zig` does not export it. Export it there as `pub const native_message = @import("lib/native-message.zig");` beside `remote_control_arguments` (line 19), and create `core/src/test/native-message.test.zig`, with a description comment at the top, holding the tests listed under Unit Tests.
    - `zig build test` passes.

3. The arguments of a new instance and the process start. New file `packages/ziggy/core/src/lib/new-instance.zig`, which imports only `std` so the Linux and Windows native apps import it on their own, as they do `remote-control-arguments.zig`. Top comment: it starts another instance of the running app, with the arguments the core gave, as a process of its own that keeps the app's process group, environment, working directory and standard streams.
    - `pub fn instanceArguments(allocator: std.mem.Allocator, app_arguments: []const []const u8, remote_control: ?[]const u8) ![]const []const u8`: the app's arguments followed by `--remote-control` and the address when `remote_control` is set, so an instance under remote control connects to the same server. Fails with `error.RemoteControlArgument` when an app argument is `--remote-control`, because the new instance would then get it twice and refuse to start (`RemoteControlGivenTwice` in `remote-control-arguments.zig`). The strings are not copied. Assert the length of the result.
    - `pub fn start(gpa: std.mem.Allocator, arguments: []const []const u8) !u32`: makes a single-threaded `std.Io.Threaded` of its own (as `ownIo` in `core.zig` line 692 does), reads the running program's path with `std.process.executablePathAlloc`, and starts it with `std.process.spawn` and `.argv` the path followed by `arguments`, passing every option explicitly: `.pgid = null` (the parent's process group), `.stdin = .inherit`, `.stdout = .inherit`, `.stderr = .inherit`, `.cwd = .inherit`, `.environ_map = null`. Returns the new process's id. On Windows it reads the id with `GetProcessId`, declared as an `extern "kernel32"` function as `exec.zig` declares its own (std has no binding), and closes `child.id` and `child.thread_handle`. On other systems the id is `child.id`, and the caller reaps the process when it exits. Assert the id is above 0.
    - `packages/ziggy/core/src/index.zig`: export it as `pub const new_instance = @import("lib/new-instance.zig");` beside `remote_control_arguments` (line 19), so the core's tests reach it.
    - `build.zig`: add the import `new-instance` to the Linux native app (after line 704) and the Windows native app (after line 796), written as the `remote-control-arguments` import beside each.
    - Test `instanceArguments` in new `core/src/test/new-instance.test.zig`. `start` starts a real process and is covered by the smoke test of step 9, because a unit test stays inside its own process.
    - `zig build` and `zig build test` pass.

4. The C function macOS calls. `packages/ziggy/core/src/lib/ziggy-api.zig`: add `startInstance` to `Api`, exported as `ziggy_start_instance` beside the others (line 341):
    - `const char *ziggy_start_instance(const char *const *args, uint32_t arg_count, uint32_t *process_id);` declared in `ziggy.h` after `ziggy_inject_script` (line 220), with a comment: starts another instance of the app with the arguments, writes its process id and returns NULL, or returns the name of the error when it could not start it. The caller reaps the process when it exits.
    - It copies the arguments into slices with `std.heap.c_allocator`, calls `new_instance.start` and returns `@errorName(err)` (a static string) on failure.
    - `zig build` passes.

5. The core's side: `newWindow` in the handler services, the system message and the frontend API.
    - `packages/ziggy/core/src/lib/services.zig`: `HandlerServices.VTable` gains `newWindow: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, arguments: []const []const u8) anyerror!void`, and `HandlerServices` gains `pub fn newWindow(self, io, allocator, arguments) !void` with a comment: starts another instance of the app with the arguments, as a process of its own with its own window, backend and task queue. Under remote control the instance gets the same `--remote-control` address. Fails with `error.NewWindowUnavailable` on Android, iOS and in dev mode, with `error.RemoteControlArgument` when an argument is `--remote-control`, and with the native app's reason when the process could not start.
    - `packages/ziggy/core/src/lib/core.zig`, `MainServices` (lines 303 to 470): add `.newWindow = newWindow` to `vtable` and the function. It returns `error.NewWindowUnavailable` when `self.config.has_new_window` is false. It builds the arguments with `new_instance.instanceArguments(allocator, arguments, <config.remote_control as a slice or null>)`, posts the call `.{ .new_window = ... }` to `self.frontend.native` with a `MessageQueue` of its own as the reply queue (call id 0), and takes the reply from it, as `NativeCallbacks.request` (`services.zig`) does. Waiting on the main thread is safe: the native app's UI thread never waits on the main thread, and `NativeSide.stop` fails a pending call with `ShuttingDown` while the core stops. A reply with an error returns `errors.throwError("A new window could not start: {s}", .{reason})`. A result is parsed as a `u32` process id and the function writes `Started a new window, process <pid>.` to `self.log` at info level. Assert that the reply's request id is 0.
    - New file `packages/ziggy/core/src/lib/system-messages/window.zig`, top comment: the system message of new windows (new-window). `pub const NewWindowRequest = struct { arguments: []const []const u8 }` and `pub fn newWindow(services, io, allocator, request) !DoneResponse` calling `services.newWindow`, with its own `DoneResponse` empty struct as `action.zig` has.
    - `packages/ziggy/core/src/lib/system-messages.zig`: `pub const window = @import("system-messages/window.zig");` with a comment, and `"new-window"` added to `names` (line 51).
    - `core.zig`, `runSystem` (lines 1375 to 1445): handle `"new-window"` with `handlers_lib.parsePayload(system_messages.window.NewWindowRequest, arena, data)` and `respond`, as `run-action` is handled. An error reaches the frontend as the rejection of its promise through `reportHandlerError` (line 1361).
    - `core/src/test/registration.test.zig` (line 146): add `"new-window"` to the names checked.
    - `packages/ziggy/core/src/lib/ziggy-inject.js` (after `listActions`, line 361): `newWindow: function (args) { return invokeSystem("new-window", { arguments: args }); }`, each property of the object literal on its own line, with a comment: starts another instance of the app with the arguments, as a process of its own, and resolves once it has started.
    - `packages/ziggy/frontend/src/ziggy-bridge.ts`, `IZiggyBridge` (after `listActions`, line 319): `newWindow(args: string[]): Promise<void>;` with a comment block saying what it does and that it rejects on Android, iOS and in dev mode with `NewWindowUnavailable`.
    - `packages/ziggy/frontend/src/test/ziggy-inject.test.ts`: add `newWindow` to the type of `fakeWindow.ziggy` (line 26) and to the sorted list of methods (line 534), and add the test listed under Unit Tests.
    - `MainServices` is the only builder of a `HandlerServices.VTable` in this repository (`grep -rn "HandlerServices.VTable" packages apps` finds only `core.zig` line 324), so no test double changes.
    - `zig build test`, `bun run compile` and `bun run test` pass.

6. The Linux native app does the call. `packages/ziggy/native/linux/src/lib/native-app.zig`:
    - `start` (line 267): `config.has_new_window = true;`.
    - `doCall` (line 485): `.new_window => |arguments| startNewWindow(native_app, reply, arguments),`.
    - New `fn startNewWindow(native_app: *NativeApp, reply: u64, arguments: []const []const u8) void`: calls `new_instance.start(std.heap.c_allocator, arguments)` (import `new-instance`). On failure `sendResult(native_app, reply, false, @errorName(err))`. On success it registers `g_child_watch_add(pid, onNewWindowExited, null)`, so GLib reaps the process when it exits, then `sendResult` with the id as JSON text. The window is started from the GTK main thread, so the child watch is on the main loop that runs the app.
    - New `fn onNewWindowExited(pid: c_int, wait_status: c_int, user_data: c.gpointer) callconv(.c) void`, with a comment: GLib has reaped the instance by the time it calls this; the instance is an app of its own, so its exit leaves this app as it is.
    - `packages/ziggy/native/linux/src/lib/gtk.zig`: declare `pub const GChildWatchFunc = *const fn (pid: c_int, wait_status: c_int, user_data: gpointer) callconv(.c) void;` and `pub extern fn g_child_watch_add(pid: c_int, function: GChildWatchFunc, data: gpointer) c_uint;`, checked against `/usr/include/glib-2.0/glib/gmain.h` (line 814 and the `GChildWatchFunc` typedef), with a comment on each as the file's other declarations have.
    - `zig build` passes.

7. The Windows native app does the call. `packages/ziggy/native/windows/src/lib/native-app.zig`:
    - `onControllerCreated` (line 896): `config.has_new_window = true;`.
    - `doCall` (line 813): `.new_window => |arguments| startNewWindow(native_app, reply, arguments),`. The name `startNewWindow` keeps it apart from `newWindowInvoke`, which handles WebView2's own NewWindowRequested event.
    - New `fn startNewWindow(native_app: *NativeApp, reply: u64, arguments: []const []const u8) void`: calls `new_instance.start(std.heap.c_allocator, arguments)` and sends the id or `@errorName(err)` with `sendResult`. `start` has already closed the process's handles, so the process needs no wait.
    - Both instances use the same WebView2 user data folder (`<LOCALAPPDATA>\<app id>\WebView2`, line 495). The smoke scenario of step 9 starts the second window on that folder on Windows.
    - `zig build` passes, including the Windows cross build of `bun run compile:zig`.

8. The macOS native app does the call. `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`:
    - `start` (line 219): `config.has_new_window = true`.
    - `doCall` (line 327): `case "new-window":` reads `call["arguments"]` as `[String]` (`ZiggyBridge.fail` naming the call when it is missing), then calls `startNewWindow(arguments, reply: reply)`.
    - New `private func startNewWindow(_ arguments: [String], reply: UInt64)`: duplicates each argument with `ZiggyBridge.duplicate` into an array of C strings, calls `ziggy_start_instance(pointer, UInt32(arguments.count), &processId)`, frees the copies, and on a non-nil result `finishCall(reply, ok: false, text: String(cString: result))`. On success it makes `DispatchSource.makeProcessSource(identifier: pid_t(processId), eventMask: .exit, queue: .main)` whose handler calls `waitpid(pid_t(processId), &status, 0)`, cancels the source and removes it from a new `private var newWindowWatches: [Int32: DispatchSourceProcess]` property that keeps each source alive, resumes it and then `finishCall(reply, ok: true, text: String(processId))`. `ziggy_start_instance` runs the executable inside the app's bundle (`Contents/MacOS/<name>`), so the instance stays in the parent's process group.
    - Every API used is in the macOS 12 SDK of Xcode 14.2: `DispatchSource.makeProcessSource` and `waitpid` predate it.
    - iOS (`native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift`) is not changed: its config is zeroed, so `has_new_window` is false and the core never sends it the call.
    - The Swift package builds on a Mac (`swift build` in `packages/ziggy`, CI-only from this Linux machine).

9. The template's and the test app's "New Window" action, the Linux display of the smoke tests and the smoke scenario.
    - `apps/ziggy-template/backend/src/lib/actions.zig`: add `.{ .name = "new-window", .label = "New Window", .shortcut = "CmdOrCtrl+N" }`, each field on its own line, with the comment that it opens another window of the template as a process of its own. `apps/ziggy-template/backend/src/lib/menu.zig`: add `.{ .run = .{ .action = "new-window" } }` (each field on its own line) at the top of the File menu (line 37), with the comment that it runs the template's action New Window, whose label and shortcut the item shows, written as the `hello-from-action` item on the Hello menu (line 152).
    - `apps/ziggy-template/frontend/src/main.ts`, `registerActions` (line 101): `window.ziggy.registerAction("new-window", openNewWindow)`, with a new `function openNewWindow(): Promise<void>` that calls `window.ziggy.newWindow([])` and, on rejection, writes `The new window did not open: <message>` with the template's `log` function, as `listenForTheActionButton` does.
    - `apps/ziggy-test-app/backend/src/lib/handlers.zig`: the same action in `actions` (line 989) and the same File menu item in `menu` (line 1002). `apps/ziggy-test-app/frontend/src/main.ts`, `startActions` (line 559): register `new-window` with a handler that calls `window.ziggy.newWindow(["-geometry=640x480"])` and on rejection writes `the new window did not open: <message>` to `action-result`. Every desktop native app of the test app reads `-geometry=` (`native/linux/src/main.zig`, `native/windows/src/main.zig`, `native/macos/ZiggyTestApp/AppDelegate.swift` line 47), and its default width is 900.
    - Check the action list scenario `smoke-tests/27-actions/test.sh` still passes: it looks for `say-action` and `quit` in the list and no other name.
    - `smoke-tests/lib/linux.sh` and `apps/ziggy-template/smoke-tests/lib/linux.sh`, `ziggy_platform_start` (line 39): start `Xvfb -displayfd 3 -nolisten tcp -screen 0 1280x1024x24 3>"$test_dir/xvfb.display"` with `launch_in_process_group` into `$test_dir/xvfb.log`, record its group in `$test_dir/xvfb.pgid`, wait (up to `WAIT_TIMEOUT_SECONDS`, once every 0.1 seconds, as `ziggy_platform_wait_exit` waits) until `xvfb.display` holds a number, then start the app with `launch_in_process_group` and `env DISPLAY=":<number>"` in place of `xvfb-run -a -s ...`. `/usr/bin/xvfb-run` kills the X server as soon as the command it ran exits (its `clean_up`), which would end a second window when the first is closed, and the app's group would hold `xvfb-run` and Xvfb as well as the app. `ziggy_platform_stop` ends the app's group first and then Xvfb's. A display chosen by `-displayfd` is free, so runs beside each other never share one. Update the comment at the top of each file. `bash -n` passes on both.
    - `smoke-tests/lib/windows.sh`, `ziggy_platform_stop` (line 52), written for Open question 1 option A: before ending the app's group, read every `Started a new window, process <pid>.` line from the log files under `$(ziggy_platform_data_dir "$test_dir")/logs` and end each process with `taskkill //F //PID <pid>`, ignoring a process that has already gone. Update the comment above it. `bash -n` passes.
    - New scenario `smoke-tests/desktop-only/29-new-window/test.sh` (executable, `#!/usr/bin/env bash`, sourcing `../../lib/common.sh`). Use the next unused number when 29 is taken by the time this step runs, here and in `run.md`. Top comment: a menu item opens a second window as a process of its own with the arguments its action gives, under the same remote control server, and closing the first window leaves the second running. It runs on Linux, Windows and macOS, because Android and iOS have no new window.
        - `start_test_app`, then `wait_for_windows '[1]'`.
        - `choose_menu_item new-window`, then `wait_for_windows '[1,2]'` and `wait_for_ready 2`.
        - The viewport width of window 2 (`window_control 2 '{"command":"viewport"}' | jq -r '.value'`, the part before `x`) is at most 640, and window 1's (`viewport_size`) is above 640, which shows the new window got `-geometry=640x480`.
        - `click run-say-action` on window 2 through `window_control 2 '{"command":"click","dataId":"run-say-action"}'`, then window 2's `get-text` of `action-result` contains `said by an action` and window 1's `text_of action-result` does not, which shows each window runs its own backend and frontend.
        - `control '{"command":"quit"}'` ends window 1; then `wait_for_windows '[2]'` and `wait_for_ready 2`, which shows closing a window leaves the other running.
        - `ziggy_platform_stop "$ZIGGY_TEST_DIR"`, then `wait_for_windows '[]'`, which shows the harness's stop of the first window's process group (on Windows, the log lines of Open question 1) also ended the window it started.
        - Add the scenario to the `desktop-only` list in `smoke-tests/run.md`.
    - `bun run compile`, `bun run test`, `zig build` and `bun run test:smoke` pass on Linux.

10. Upgrade notes and documentation. `docs/upgrade-notes.md`: under `## v0.0.24` (add the heading above `## v0.0.23` when the file has none), add:
    - **`HandlerServices.VTable` has `newWindow`.** Code of the app's that builds its own handler services vtable, such as a test, adds a `newWindow` entry.
    - **`window.ziggy` has `newWindow`.** A fake of `IZiggyBridge` in the app's tests adds it.
    - **`ziggy_config` has `has_new_window`.** Native code of the app's own that fills a `ziggy_config` field by field sets it.
    - **The log files are named `<name>-<start time>-<process id>.log`.** A test or script of the app's that matches the file name exactly allows for the process id.
    - **The Linux smoke library starts Xvfb itself.** An app that copied the template's `smoke-tests/lib/linux.sh` copies the new one.
    - **New, and optional:** a new window, opened with `window.ziggy.newWindow(arguments)` or `HandlerServices.newWindow` (see [New windows](user-guide/new-windows.md)).

### Photosphere repository

11. Take the new interface members against the local Ziggy. Photosphere's `build.zig.zon` keeps its locked Ziggy tag: every Zig command in this step adds `--fork="$HOME/projects/photosphere/ziggy"`, which builds against the local Ziggy checkout (the way Photosphere's `CLAUDE.md` gives for a change that spans both).
    - `packages-zig/photosphere-core/src/test/main-state.test.zig`, the test vtable (line 75): add `.newWindow = newWindow` and a `fn newWindow(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const []const u8) anyerror!void` that calls `unexpected("newWindow")`, as `runAction` does (line 129).
    - `apps/photosphere-frontend/src/test/fake-ziggy.ts`, `FakeZiggy` (after `listActions`, line 178): `async newWindow(args: string[]): Promise<void>` that throws `Error("FakeZiggy: Photosphere opens no new window, so newWindow was not expected (arguments ${args.join(" ")}).")`, with a comment above it, as `runAction` throws for a missing handler.
    - `docs/photosphere-on-ziggy.md` (line 35): the log files are `photosphere-<time>-<process id>.log` and `-errors.log`.
    - Check every smoke library that finds the log file by name still matches: `apps/photosphere-smoke-tests/lib/android.sh` (line 407), `lib/ios.sh` (line 218) and `lib/ios-device.sh` (line 320) match `photosphere-*.log` and leave out `-errors.log`, which still holds.
    - `zig build --fork="$HOME/projects/photosphere/ziggy"`, `zig build test -Dcpu=baseline --fork="$HOME/projects/photosphere/ziggy"` and `bun run compile` pass, and `bun run test -- fake-ziggy` passes.

### Example repositories

12. `ziggy-example-vite` and `ziggy-example-rsbuild` are not changed. Each locks Ziggy to a tag and holds no handler services vtable and no `IZiggyBridge` fake (`grep` for `IZiggyBridge`, `HandlerServices.VTable` and `listActions` finds none), so they keep building, and they take the template's New Window action when they move to the Ziggy release that carries it, as Ziggy's `CLAUDE.md` requires for every release.

### Documentation

13. Write the documentation in the Ziggy repository.
    - New `docs/user-guide/new-windows.md`, linked from `docs/user-guide.md` beside Actions: what a new window is (another instance of the app, a process of its own with one window and its own backend and task queue, started from the running program's own executable, in its process group, with its environment and working directory); how to open one from the frontend (`window.ziggy.newWindow(arguments)`, usually from an action's handler, as the template's File > New Window does) and from the backend (`services.newWindow`); that closing one never ends the others; that under remote control the new window gets the same `--remote-control` and is the next window number on the server; that it fails with `NewWindowUnavailable` on Android, iOS and in dev mode and why; that instances share the data directory, the config and state files and the web view's data, so two can change the same file at once.
    - `docs/user-guide/actions.md`, "On each platform" (line 92): a line on the template's New Window action and a link to the new page.
    - `docs/user-guide/logging.md` (lines 67 and 89): the file names carry the process id, so two instances never share a file.
    - `docs/user-guide/testing.md`, "The remote control connection": a window an app opens connects to the same server, and on Linux and macOS ends with the app's process group; on Windows the smoke library ends each window by the process id the app's log records.
    - `docs/development/architecture.md`: the `new-window` call beside `quit` and `screenshot`, `has_new_window`, `ziggy_start_instance` and that the Linux and Windows native apps import `new-instance.zig`.
    - `smoke-tests/lib/process-control.md` only when it describes how the Linux app is started under `xvfb-run`.

## Unit Tests

- `log/src/test/file-log.test.zig`: the log and error log names hold the process id after the start time (updated test).
- New `core/src/test/native-message.test.zig`: `new-window` encodes with its arguments in order and parses back to the same arguments; an empty argument list round-trips; `new-window` without `arguments` is `InvalidCall`.
- `core/src/test/new-instance.test.zig`, `instanceArguments`: without remote control the arguments come back unchanged and in order; with remote control `--remote-control` and the address follow them; an empty list with remote control is the option and its address alone; an app argument `--remote-control` fails with `RemoteControlArgument`.
- `core/src/test/dispatcher.test.zig`, through the fake native app:
    - a `new-window` system message with `{"arguments":["-geometry=640x480"]}` sends the native app the call `{"type":"new-window","arguments":["-geometry=640x480"],...}` (read with the fake's `last-call`) and responds with `{}`;
    - with `remote_control` set in the config, the call's arguments end with `--remote-control` and the address;
    - with `has_new_window` false, the message's response is the error `NewWindowUnavailable` and no call reaches the native app;
    - a native result that fails (set on the fake for `new-window`) gives the error `A new window could not start: <reason>`;
    - an argument `--remote-control` gives `RemoteControlArgument`;
    - a successful call writes `Started a new window, process 4242.` to the app's log.
- `core/src/test/registration.test.zig`: `new-window` is one of the system messages.
- `frontend/src/test/ziggy-inject.test.ts`: `newWindow(["a", "b"])` posts `{"kind":"system","name":"new-window","data":{"arguments":["a","b"]}}` with an id and resolves with the response; `newWindow` is in the list of methods.
- Each new or edited function of the Linux, Windows and macOS native apps (`startNewWindow`, `onNewWindowExited`) and `new_instance.start` and `ziggy_start_instance` start real processes and are covered by the smoke scenario, not by unit tests.

## Smoke Tests

- New `smoke-tests/desktop-only/29-new-window` on Linux, Windows and macOS: the menu item opens window 2 with the arguments its action gives; window 2 runs its own frontend and backend; quitting window 1 leaves window 2 running; stopping the first window's process group (or, on Windows, the log's process ids) ends window 2.
- Every existing scenario of `smoke-tests` and of `apps/ziggy-template/smoke-tests` on Linux, which now start Xvfb themselves.
- `smoke-tests/26-log-files`, which finds the log files by `ziggy-test-app-*.log`, on every platform.
- `smoke-tests/27-actions`, with the new action in the list, on every platform.
- Photosphere's `bun run test:ziggy` on Linux, whose libraries find the log file by name.

## Verify

- Ziggy, on Linux: `zig build`, `zig build test`, `bun run compile`, `bun run test`, `bun run compile:zig` and `bun run test:smoke` exit 0, and `bun run --filter=ziggy-template test:smoke` exits 0.
- Ziggy, on Linux or macOS with an Android device or emulator attached (`adb devices` shows one in state `device`): `bun run test:android-shell`, `bun run test:zig:android` and `bun run test:smoke:android` exit 0, because the core and `jni.zig` changed.
- Ziggy, on macOS: `bun run test:zig:ios`, `bun run test:smoke:ios` and `bun run test:smoke` exit 0. CI-only from Linux.
- Ziggy, on Windows: `bun run test:smoke` exits 0, with `29-new-window` passing and no `ziggy-test-app.exe` of the run left running afterwards. CI-only from Linux.
- `bash -n` passes on every edited shell script.
- Photosphere, on Linux: `zig build --fork="$HOME/projects/photosphere/ziggy"`, `zig build test -Dcpu=baseline --fork="$HOME/projects/photosphere/ziggy"`, `bun run compile` and `bun run test` exit 0.
- `grep -rn "xvfb-run" smoke-tests/lib apps/ziggy-template/smoke-tests/lib` in Ziggy prints no line.

## Notes

- Mechanisms checked against the code: Zig 0.16's `std.process.spawn` calls `setpgid` only when `pgid` is set (`std/Io/Threaded.zig` line 15004), so a null `pgid` keeps the parent's group; `std.process.executablePath` follows the running executable on Linux, Windows and macOS; GLib reaps a child only through a child watch or without `G_SPAWN_DO_NOT_REAP_CHILD` (`gspawn.h` line 148), so a process started with Zig's spawn needs `g_child_watch_add`; the Linux GTK application is `G_APPLICATION_NON_UNIQUE` (`native-app.zig` line 114), so a second instance opens its own window instead of handing over to the first; the macOS template quits when its last window closes (`AppDelegate.swift` line 38); `xvfb-run` kills its X server when its command exits (`/usr/bin/xvfb-run`, `clean_up`); `Xvfb` takes `-displayfd`; the file log names its files by the start time in whole seconds (`file-log.zig` line 91).
- Spawning in the native app instead of the core: the core has no main loop to reap a child on, while GTK and Grand Central Dispatch each do, and starting the app's own executable is the native app's business on macOS, where the executable lives in a bundle. The shared Zig in `new-instance.zig` keeps a single implementation of the start itself for every desktop platform.
- `window.ziggy.newWindow` takes the arguments from the app, because what a new window opens (a repository, a database) is the app's to choose. A standard action takes no arguments, so New Window is an app action whose handler calls `newWindow`, which also keeps the shortcut and menu placement the app's.
- The arguments after the program's name are the app's own. Of the parent's command line the new instance gets only `--remote-control`, so `-geometry=` and the app's options are passed only when the app passes them.
- Instances share the data directory, so the web view's stored data, the config and the state file are shared. Atomic config and state updates are the work of plan-config-and-state.md.
- Two WebKitGTK or WebView2 processes on the same data folder are exercised by `29-new-window` on each desktop platform. On Windows that run is in CI.
- Android and iOS were checked and rejected for a new window: `jni.zig` holds one bridge per process and the iOS bridge one core, an Android multi-instance task or iPad scene runs inside the same process, and the feature requires a separate process with its own backend.
- Dev mode has no new window: its frontend is a browser tab served by one dev host, and a second dev host would need a port and a browser tab of its own.
- The remote control server holding several apps, numbering them, `"window": n` and listing the windows are plan-remote-control-window-targeting.md's work. With that plan's numbering, a window keeps its number while others close.
- The process id log line is written by the core for every platform, so it is the same text on each.
