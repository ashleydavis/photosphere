# Ziggy architecture

Ziggy is an application shell that delivers an app to Windows, MacOS, Linux, Android and iOS. The user interface is TypeScript, CSS and HTML running in the system web view of each platform. Everything else is Zig. Photosphere is the app built on it, and the last section says how Photosphere uses each part.

## Terms

- **Page:** the user interface running inside the web view.
- **Core:** the Zig library that holds the app's logic and state.
- **Shell:** the native program for one platform that hosts the web view and the core.
- **Handle:** the value `ziggy_create` returns to stand for one running core. The shell passes it back on every call.
- **Message:** a JSON object passed between the page and the core.
- **Channel:** the name of a kind of message, such as `add-task`. The core routes each message to the handler registered for its channel.
- **Request, reply and event:** a request goes from the page to the core and expects a reply. An event goes from the core to the page and expects no reply.
- **Dispatcher:** the part of the core that reads a message and passes it to the handler for its channel.
- **Handler:** the Zig function that runs for a channel or a task type.
- **Platform layer:** the small TypeScript module in the user interface that implements the app's platform abstraction on top of `window.ziggy`. It is the only place that knows the app is running on Ziggy.
- **Shared UI:** the user interface code that runs unchanged on every platform and knows nothing about Ziggy.
- **Task:** work that runs on a worker thread and reports back by messages. Its **task type** names the handler that runs it.
- **Task context:** what a running task is given to work with: `sendMessage` to report, `isCancelled` to check whether it should stop, and the means to queue child tasks and wait for them.
- **Source:** a label a task is queued under. Cancelling a source cancels every task queued under it.
- **Native host callback:** a function the shell registers with the core so the core can ask the operating system for something it cannot do itself, such as showing a file dialog.
- **Loopback:** the address `127.0.0.1`, reachable only from the same machine.
- **UI thread:** the one thread of a shell that is allowed to touch the window and the web view.

## Parts

- **Core library**: a Zig library. It exposes a C interface, holds all state behind one handle, runs the task handlers on a pool of threads and answers every message the page sends. An app adds its own channel handlers and task handlers to it, and builds the result as a static library for every target and as a shared library for Android.
- **Shells**: one per platform. A shell creates a window, hosts the system web view, injects the `window.ziggy` script, loads the bundled page, calls `ziggy_create`, forwards page messages to Zig and Zig messages to the page. A shell does nothing else except what the operating system forces (menus, dialogs, drag and drop, background scheduling, photo library access).
- **User interface**: the TypeScript app that runs in the web view, with a small platform layer that connects it to `window.ziggy`.
- **Zig packages**: the libraries the core depends on, by relative path.

Ziggy and the app built on it are kept in separate places. Ziggy's code never names the app and never imports its packages. The app uses Ziggy only through its interfaces: the C interface, `window.ziggy`, handler registration in the dispatcher and the task runner, and the host callbacks. The next section lists where each lives for Photosphere.

## Languages and shells

| Platform | Shell | Web view |
|---|---|---|
| Linux | Zig executable | WebKitGTK 4.1 with GTK 3 |
| Windows | Zig executable | WebView2 |
| MacOS | Swift | WKWebView |
| Android | Java activity, JNI entry points written in Zig | Android WebView |
| iOS | Swift | WKWebView |

Every platform has its own native project.

## The message bridge

The page reaches Zig by JSON messages.

Each shell injects a script before the page loads that exposes only `window.ziggy`, with `invoke`, `send`, `onMessage` and `removeAllListeners`. UI code never uses the web view's own native handle (`window.chrome.webview`, `window.webkit.messageHandlers`, the Android interface object) directly.

A message from the page is `{ "id", "channel", "data" }`. A reply is `{ "id", "ok", "data" }` or `{ "id", "ok": false, "error" }`. An unknown channel gets an error reply, never silence. A one-way message (`send`) has no reply. An event from Zig to the page is `{ "channel", "data" }`.

### The C interface

The shells are written in Swift, Java and Zig, and the core is Zig. Every shell reaches the core through the same C interface, because C is the one calling convention all three can use. It is declared in `ziggy.h`, beside the API file:

- `ziggy_create(callbacks)` returns the handle. `callbacks` holds the function pointer that delivers a JSON message from Zig to the shell, a function pointer for each native host callback the shell provides (see "Native host callbacks"), and a user-data pointer the shell supplies. Pool sizes and the child task limit are also passed in here.
- `ziggy_destroy(handle)` cancels every running task, waits for the workers to stop and releases everything. No task runs after it returns.
- `ziggy_post_message(handle, json_ptr, json_len)` delivers a page message to Zig.

A message passed in either direction is valid only while the call or callback carrying it is running. The receiver copies it before returning and nothing is freed across the boundary. The callback can be invoked from any worker thread, so each shell delivers the message to the web view on its UI thread. The core never assumes which thread calls it.

### Delivering a message to the page

1. Zig builds a JSON message, either a reply or an event, from any thread.
2. The core calls the callback the shell gave `ziggy_create`, passing the message.
3. The shell copies the message and moves to its UI thread.
4. The shell runs it in the web view: `webkit_web_view_evaluate_javascript` on Linux, WebView2's web message API on Windows, JavaScript evaluation on a `WKWebView` on MacOS and iOS, and `evaluateJavascript` on Android.
5. The injected `window.ziggy` script receives it. A reply resolves the pending `invoke` promise with the same `id`. An event calls the `onMessage` callbacks registered for its channel.

### Sending a message from the page

1. The page calls `window.ziggy.invoke(channel, data)` or `window.ziggy.send(channel, data)`. `invoke` gives the message an `id` and keeps a pending promise under it, and `send` has no `id` and no promise.
2. The injected script posts the JSON message to the shell: through a `WebKitUserContentManager` script message handler on Linux, WebView2's web message API on Windows, a `WKScriptMessageHandler` on MacOS and iOS, and the `addJavascriptInterface` object on Android.
3. The shell receives it on its UI thread and passes it to `ziggy_post_message`.
4. The core parses it and routes it by `channel` to its handler, on a worker thread when the handler is a task. An unknown channel gets an error reply.
5. If the message had an `id`, the reply returns to the page by the route above.

### Origin check

A shell accepts messages only from the app's own bundled page, blocks navigation to anything else, and opens external links in the system browser. Whether an address is the app's own is a Zig function in the core (`origin-check.zig`) called by the shell, so it is written and tested once.

## Tasks

The task runner runs handlers on a pool of threads inside the core. It provides task types, task messages, task context (`sendMessage`, `isCancelled`, `maxConcurrentChildTasks`, child tasks queued and awaited), priorities and cancellation by source. The page queues work with `add-task` and cancels with `cancel-tasks`, and receives `task-message` and `task-completed` events.

- The shell passes the worker thread count and one child task limit, which applies to every parent task, to `ziggy_create`.
- Children run on the same pool as their parent. A parent that waits for children gives up its place on a worker thread while it waits, so the pool cannot deadlock when every worker is held by a waiting parent.
- Cancelling a source cancels its queued and running tasks, including children. A failed child makes `awaitTask` return its failure to the parent.

## Messages that belong to Ziggy

- `add-task` and `cancel-tasks` from the page, which queue and cancel tasks.
- `task-message` and `task-completed` to the page, which report a task's messages and its end.
- `get-platform`, which reports `platformKind` (`desktop` or `mobile`) so the platform layer does not sniff the user agent.

Every other message belongs to the app. Request and reply types for all messages are defined in `protocol.zig` in the core, which is the source of truth for every payload.

## Channels

A channel is how the page and the core talk. The page sends requests on a channel and the core answers, and the core sends events on a channel to the page. A channel connects the page and the core, and the shell only carries its messages.

To add a channel:

1. Prefer an existing channel. Send a named action from the page to the core through one generic command channel that takes the action's name, rather than adding a channel per action (for example a dedicated channel to toggle developer tools).
2. If a new channel is unavoidable, define its request and reply types in `protocol.zig`.
3. Write the handler in the core, register it in the dispatcher, and write its unit test beside the core's other tests.
4. Platform-specific code never goes in the shared UI. The platform layer passes platform behaviour into it through the platform abstraction the shared UI defines.

## Native host callbacks

A native host callback is how the core asks the operating system for something only native code can do, such as showing a file dialog, reading the photo library or scheduling background work. It is a function the shell provides, and a channel is not involved: the page never sees it. A callback connects the core and the shell.

- **Registration:** the shell puts a function pointer for each callback it provides in the `callbacks` struct it passes to `ziggy_create`, with its user-data pointer. The core keeps them in the handle. A callback the platform does not need is left empty, and the core fails with a clear error if it calls one that is empty.
- **Calling:** the core calls the function from a worker thread and waits for it to return. The shell does the work on its UI thread and returns the result, so a callback that waits for the user, like a dialog, must be called from a task and never from the dispatcher.
- **Result:** the function returns its result as a JSON message, valid only until the next call, and the core copies it, as for any message across the C interface.

To add a native host callback:

1. Declare its function pointer in `ziggy.h` and add it to the `callbacks` struct.
2. Implement it in every shell that supports it, on the shell's UI thread.
3. Call it from the core's handler and write the unit test with a test implementation of the callback.

### The file and folder dialogs

The `pick_paths` callback shows a native dialog: it is given what to show (open files, save a file, or choose a folder), a title and a suggested file name for a save, and a buffer it writes the answer into as a JSON array of paths, `[]` when the user cancelled. The shell shows the dialog on its UI thread and the calling worker thread waits, so the window stays responsive. A task asks for it with `pickPaths` on its task context.

A request channel can be answered by a task, so a slow answer such as a dialog never holds up the thread that handles page messages: an app lists it in `task_channels` with the task type that answers it, and the core queues the page's request as that task and sends the reply when it ends. A task that fails or is cancelled gives an error reply, and a request without an id is an error.

The Ziggy example answers `pick-files`, `pick-folder` and `pick-file` this way, with the same names, data and replies as the Electron app: `pick-files` takes a title and replies with the paths or null, `pick-folder` takes an options object that may carry a `title` and replies with a path or null, and `pick-file` is a save dialog that takes a suggested file name and replies with a path or null. Null is a cancelled dialog, which Electron gives as undefined. A phone has no save dialog of this kind, so `pick-file` replies with an error on iOS.

## Menus

A desktop app has a menu, written once in Zig and drawn natively by the shell of each desktop platform: a menu bar in the window on Linux and Windows, and the main menu on MacOS. A phone's shell never draws it.

The app gives the core its menu as JSON text in `menu_json` of its handlers. It is an array of menus, each `{"label", "items"}`, where an item is `{"label", "action", "accelerator"}`, or `{"separator": true}`, and may hold its own `"items"` for a submenu. A shell reads the text with `ziggy_menu_json` and reads each shortcut with `ziggy_parse_accelerator`, which gives modifier bits and a key name so no shell parses shortcut text itself. A shortcut is modifiers and a key joined by plus signs, in Electron's form: `CmdOrCtrl+Shift+I`, `F12`, `CmdOrCtrl+Plus`. `CmdOrCtrl` is Command on MacOS and Control elsewhere.

Every shell does these actions itself, because only the shell can: `quit`, `reload`, `toggle-devtools`, `toggle-fullscreen`, `zoom-in`, `zoom-out`, `zoom-reset`, `undo`, `redo`, `cut`, `copy`, `paste` and `select-all`. Any other action is the app's. The shell sends `{"channel": "menu-action", "data": {"action": "<action>"}}` to the core, and the core hands it to the page as a `menu-action` event. The page decides what it means, and the example's page presses the same button the item stands for.

Shortcuts are registered with the window, so they work wherever the focus is, including inside the web view.

The developer tools open with `toggle-devtools` in every build, release included, and are not a test hook.

## Test hooks

A test hook is a feature that exists in the shipped app only so that automated tests can control it or look inside it. Smoke tests drive the real app from outside, and some things cannot be reached that way. A script cannot click a native file dialog, cannot read what the web view shows, and cannot wait for the page to finish loading, so the app has to offer a way in.

Test hooks are also a way into the app that a normal run must not have, so they are kept out of anything released. The hooks are compiled in only when the app is built for testing, with the core's `test_hooks` build option, which is off by default. The release packages are never built with it, so a released app contains no test mode, no control connection and no dialog overrides to switch on. The smoke tests and the story player run the test build. An app ships only the hooks it lists, and a test sets up its state from outside the app (config files and data placed on disk) wherever it can. These are the hooks Ziggy provides, each with why the tests cannot do without it.

| Hook | Why the tests need it |
|---|---|
| A test mode switch read at start-up and passed to the page as the `testMode` query parameter, present only in a test build | Switches on the other hooks, and nothing below is reachable without it |
| A host-side control connection, present only in a test build, bound to loopback on an operating-system chosen port written to a file under the log directory | Lets the smoke test scripts and the story player send commands to the running app: ready, navigate, menu, click, type, drop, get-value, screenshot, cycle-advance and quit |
| The control connection's `pick-answer` command, `{"command": "pick-answer", "paths": [...]}`, in a test build | A native dialog cannot be driven from a script. The answer is used for the next dialog only, and no dialog is shown |
| In a test build in test mode, anything the app does by itself over the network is skipped, the single-instance rule is skipped, and any fixed network port is replaced by a free one | Stops tests depending on the network, on each other and on a fixed port |

The shells read two environment variables, and only in a test build: `ZIGGY_TEST_MODE` switches the hooks on and `ZIGGY_TEST_PORT_FILE` is the file the core writes the control connection's port to (on Android the same two arrive as Intent extras, and on the iOS simulator as `SIMCTL_CHILD_`-prefixed variables). A command is one line holding a JSON object with a `command` field. The core answers `quit` itself, through the shell's quit callback, and forwards every other command to the page as a `test-command` event. The page answers on the `test-result` channel, and the answer is written back as one line. The Ziggy example's page performs `ready`, `click`, `type`, `get-value`, `get-text`, and `exists`, by `data-id`. The page tells the core it is listening with `test-page-ready`, and the core holds commands until then. The control connection serves each connection on a thread of its own and handles one command at a time. The control connection's `menu` command, `{"command": "menu", "action": "..."}`, chooses a menu item as a user would: the core calls the shell's `menu_action` host callback, which runs the same function a menu click runs, so the shell's own actions (reload, zoom, developer tools, the editing commands, quit) really happen and any other action reaches the page. Choosing reload makes commands wait until the page says it is listening again. The example's page also answers `viewport` (the size of the area it is drawn in) and `insert` (type text so the browser can undo it).

## Photosphere on Ziggy

Ziggy lives here:

- `packages-zig/ziggy-core`: the core library (the C interface, dispatcher, task runner, origin check, host callback plumbing and test hooks).
- `packages/ziggy-bridge`: the `window.ziggy` script and its types.
- `packages-zig/ziggy-shell-linux`, `packages-zig/ziggy-shell-windows`, `packages-swift/ziggy-shell-apple` and `packages-android/ziggy-shell-android`: the framework half of each shell.

The Ziggy example, a small complete app built on Ziggy and kept as the reference for building an app on it, lives in `apps/ziggy-example` (its page, native projects, scripts and smoke tests) and `packages-zig/ziggy-example-core` (its handlers). See its [README](../apps/ziggy-example/README.md). It is also a standing test that Ziggy has not become tangled with Photosphere: its smoke tests run in every full test run, and Ziggy never names an app.

Photosphere lives here:

- **Core library:** `packages-zig/photosphere-core`, which adds Photosphere's channel handlers and task handlers to Ziggy's core and builds the libraries the shells link.
- **Shells:** `apps/photosphere/shells/<platform>/photosphere`, the app half of each shell: the photo library, pickers, menu content, permission strings and background work. The iOS project builds with Xcode 14.2 on macOS 12.7.6, and no version is raised.
- **User interface:** the shared `packages/user-interface`, with its platform layer in `apps/photosphere-frontend`. The layer implements the shared UI's `IQueueBackend` (the queue backend) and `IPlatformContext` (the platform provider) on top of `window.ziggy`.
- **Zig packages:** the existing ports of the TypeScript packages in `packages-zig/*`. The rest of the non-UI TypeScript is ported into them, each Zig file beside the Zig package that mirrors the TypeScript package it came from.

**Asset server:** images, video and asset writes go through an HTTP server on loopback that the core runs, not through JSON messages. It binds `127.0.0.1` at a port the operating system chooses and serves `GET /asset`, `POST /asset` and `POST /apply-database-ops`. The core reports the port to the page in an `asset-server-ready` message, which is also passed to the page as the `restApiUrl` query parameter.

**Messages:** every message other than Ziggy's own is Photosphere's: databases, secrets, config, state, import, sharing, notifications, pickers and the mobile permission and export calls. Photosphere's generic command channel for named actions is `main-command`.

**Jobs:** background work the user can see and stop is grouped into named jobs, and jobs live only in the frontend. Whatever queues the task puts an `IJobTag` (`id`, `name`, and `cancelSource` when it can be cancelled from the interface) in the task's input data, and the handler reports with `sendJobProgress`. Nothing in Zig keeps job state or decides when a job is over. The interface counts the tasks reporting each job id and drops the row when the last one completes.

**Adding a task type:**

1. Write the handler in Zig. For a port of a TypeScript handler, put it in `packages-zig/node-api-zig/src/lib/<name>.worker.zig`, one file per `.worker.ts`, keeping the function names and control flow.
2. Register it in `packages-zig/node-api-zig/src/lib/task-handlers.zig` under the same task type string the TypeScript uses.
3. Report progress with the task context's `sendMessage`. For a job, report `job-progress` messages through `sendJobProgress`, with the same fields as `packages/task-queue/src/lib/job-progress.ts`, carrying the `IJobTag` found in the task's input data.
4. Check `isCancelled` at every step of long work and finish as cancelled when it is set.
5. The queue backend in `apps/photosphere-frontend` forwards `add-task`, `cancel-tasks`, `task-message` and `task-completed`, and the jobs indicator and sidebar list show the job.
6. Write the unit test in the package, and a smoke test scenario when the task is reachable from a page.

**Test hooks:** the test mode switch is `PHOTOSPHERE_TEST_MODE=1`. The shared `packages/user-interface/src/lib/test-driver.ts` performs `click`, `type`, `get-value` and the other DOM actions by `data-id` in the page. `PHOTOSPHERE_TEST_PICK_FILE_PATH` and `PHOTOSPHERE_TEST_DOWNLOAD_FOLDER` answer the file and folder dialogs. In test mode the update check and news check are skipped, and the MCP server binds a free port. The test task types `hello-short`, `hello-long`, `hello-child` and `hello-fail` finish quickly, run for a chosen time, queue children and fail on demand, and no real task does all of these.

**Stories:** the stories browser in `packages/user-interface` runs unchanged on every platform. On desktop it opens from the Developer menu, whose content the core defines, and on Android and iOS from the hidden Developer screen. The story player (`stories:ziggy`, `stories:ziggy:and`, `stories:ziggy:ios`) launches the app in test mode, navigates it to the stories cycle and takes a screenshot of each story through the test control connection. The Android and iOS runs render every page at phone resolution, which is how pages that do not fit a small screen are found. See the [stories README](../packages/user-interface/src/stories/README.md).
