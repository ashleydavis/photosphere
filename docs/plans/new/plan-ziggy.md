# Ziggy: a Zig and system web view application shell for Photosphere

## Overview

Ziggy is a Capacitor-style application shell built only for Photosphere. It replaces the Electron desktop app and the Capacitor mobile apps with one project under `apps/photosphere` that builds, bundles and delivers Photosphere to Windows, MacOS, Linux, Android and iOS. The user interface stays TypeScript, CSS and HTML (the existing `packages/user-interface`, with the minimum set of changes needed) running in the system web view of each platform. Everything else (backend, background tasks, the asset HTTP server, shared code) is Zig, and every platform has a native shell that does nothing except host the system web view, load the Zig library, pass messages between the two, and provide the few things that must be native code. The existing `psi` port (`apps/cli-zig` and `packages-zig/*`) is the base: the rest of the non-UI TypeScript is ported to Zig as faithfully as possible, so each Zig file can be read beside the TypeScript it came from. Ziggy lives beside `apps/desktop` and the Capacitor apps until it reaches feature parity, and then those are removed in a later piece of work (not part of this plan). The work starts with Phase A, the smallest possible Hello World that shows TypeScript, HTML and Zig working together on every platform, and stops there so the human can try it on real platforms before the remaining phases begin.

Ground rules that apply to every step:

- Languages: TypeScript, shell and Zig. The native shells use these languages, approved by the human: Java for Android, Swift for iOS and MacOS, Zig for Windows and Linux, and only if Phase A shows Zig cannot host the web view on Windows then C++, and on Linux then C. No other language is used for any shell. Native code stays as small as the platform allows.
- Build systems: `build.zig` builds everything it can, including the core library for every target, the Windows and Linux shells, any C or C++ fallback shell (compiled by Zig), and the Android shared library. A second build system is used only where the platform forces it: Gradle to package the Android APK, `xcodebuild` for the Swift iOS and MacOS apps, and Vite for the UI. No Makefiles, no CMake, no other build systems, and the shell scripts in `apps/photosphere/scripts/` only call these tools in order.
- Compatibility with the existing apps: everything in Ziggy is done in a way that is recognisably compatible with the standards of the existing Electron and Capacitor projects, so someone who knows those can read Ziggy without relearning anything. That means the same channel names and message payloads, the same task types, task messages (`job-progress` included), task context (`sendMessage`, `isCancelled`, `maxConcurrentChildTasks`, child tasks queued and awaited), priorities and cancellation by source, the same `IPlatformContext` and `IQueueBackend` interfaces, the same file, folder and script naming and layout (`<n>-<name>/test.sh` scenarios, `sync`, `open`, `run` scripts, `*.worker` handler files), and the same code style and documentation habits. Where Ziggy must differ, the difference is limited to what Zig or the platform forces, and it is recorded where the code is.
- No third-party SDK or library is reimplemented, shimmed or faked. If a real library does not work somewhere (a web view library, the AWS SDK, ffmpeg), STOP and ask.
- No globals: no module-level mutable variable, no `threadlocal`. The native shells hold an opaque handle returned by the Zig library and pass it back on every call.
- No default or optional parameter values. No `any`, no `unknown`, no anonymous object types, no `ReturnType<typeof ...>` in TypeScript.
- Faithful ports: each ported Zig file sits beside the Zig package that already mirrors its TypeScript package (`packages-zig/<name>-zig`), keeps the TypeScript file name and function names (converted to Zig naming), keeps the same order and the same control flow, and is recorded function by function in `docs/zig-port-map.md`. Where Zig forces a difference, say so in a comment above the function and in the port map.
- The existing UI TypeScript and HTML (`packages/user-interface` and the Electron and Capacitor frontends) is used almost exactly as it is. The only changes permitted are the minimum needed to start the current UI on Ziggy: the platform layer in `apps/photosphere/ui` (queue backend, platform provider, entry point) and, where the existing code truly cannot run unchanged, a recorded one-line-scale edit. No redesign, no refactor, no restyling, no behaviour changes, no cleanup, no renaming. Every edit to a file outside `apps/photosphere` is listed in the "UI changes" section of `docs/ziggy-architecture.md` with the reason it could not be avoided, and the final audit reviews every one of them.
- The UI reaches Zig only through the two routes the existing apps already use. Request and event messages are JSON, carrying the same channel names and payloads as the Electron IPC channels and the mobile `JsEngine` plugin methods. Images, video and asset writes use the same three loopback HTTP routes as the existing asset server (`GET /asset`, `POST /asset`, `POST /apply-database-ops`). No new routes and no new HTTP usage are added. Platform-specific code stays out of `packages/user-interface`.
- The page talks to native code the way Electron's preload does: each shell injects a small script before the page loads that exposes only `window.ziggy` (`invoke`, `send`, `onMessage`, `removeAllListeners`). The web view's own native handle (`window.chrome.webview`, `window.webkit.messageHandlers`, the Android interface object) is never used directly by UI code and nothing wider than those four methods is exposed.
- Every shell accepts messages only from the app's own bundled page. It blocks navigation to anything else and opens external links in the system browser, as `apps/desktop/src/main.ts` does with `setWindowOpenHandler` and `will-navigate`. The decision of whether an address is the app's own is a Zig function in the core, called by the shell, so it is written and tested once.
- Test-only scaffolding in the app (a test mode, a test driver connection, test commands) needs the human's approval first. The existing apps ship a test mode switched on by `PHOTOSPHERE_TEST_MODE` that connects the shared `test-driver.ts` to a host-side control bridge. The exact hooks Ziggy proposes to ship are listed in the documentation drafted in step 1 and approved with it; nothing outside that list is added. Set test state up from outside the app wherever possible (config files and data placed on disk).
- Every function new or changed gets a unit test, every test is run and watched failing before it is accepted, and every test must survive running beside copies of itself and beside every other suite (free ports, per-test temp directories, pids recorded and killed through `kill_process_tree`). Nothing in a shell script embeds another language, and no tests are written for shell scripts. Every new script has a markdown file beside it.
- Never commit, stage or push. Never edit `.githooks/pre-commit` or `scripts/install-hooks.sh`.

## Issues

## Steps

### Phase 0: Documentation for review

1. Draft the documentation for Ziggy as it is intended to work, before any code is written, so the human can read it and understand what they are getting. Write these files, based on the research and the ground rules in this plan, and mark anything that Phase A must confirm (the web view API each platform uses, whether a desktop shell can be Zig only) as "to be confirmed in Phase A" instead of stating it as fact:
   - `docs/ziggy-architecture.md`: the architecture (core library, native shells, message bridge, asset server, task runner and jobs, how the existing UI is hosted), the rules for adding a channel or a native host callback, the rule that platform code stays out of `packages/user-interface`, a "Protocol" section listing the channels and events known from the existing Electron IPC and the mobile `JsEngine` plugin (payloads filled in during step 11), and a "UI changes" section that starts empty and lists every edit to existing UI code as it is made.
   - `apps/photosphere/README.md`: what Ziggy is for, the directory layout, how to build and run it on each platform, and which platform each script runs on.
   - `apps/photosphere/shells/<platform>/README.md` for each shell: what the shell does, the web view API it is expected to use, and how its build is expected to work.
   - `apps/photosphere-smoke-tests/README.md`: how the suites are run and how scenarios are named and organised.
   - A "Test hooks" section in `docs/ziggy-architecture.md` that lists every test-only hook Ziggy would ship for the smoke tests (what it is, why the tests cannot do without it, and how the existing Electron and mobile apps do the same thing today), so the human approves or removes each one with the documentation review.
   - An "Adding a task type" section in `docs/ziggy-architecture.md`, replacing for Ziggy what `docs/background-tasks.md` says for Electron and mobile: where the Zig handler goes, how it is registered under its task type string, how it reports progress and `IJobTag` data, and how the frontend consumes it.
   - `docs/zig-port-map.md`: a drafted block per file still to be ported (Phase E), listing the TypeScript file, the Zig file it will become, and the functions in it, filled in from reading the TypeScript, with each function's status marked "not ported yet".
   - `docs/testing/README.md` and `CLAUDE.md` (Commands and Guides sections): the drafted `test:ziggy*` entries and the link to `docs/ziggy-architecture.md`. Do not mention plans in either file.
   - The markdown file for every script the plan creates (the build, run and packaging scripts in `apps/photosphere/scripts/`, and the smoke test and fetch scripts), each saying what the script is for, how it is invoked and what each argument means.
   STOP when the drafts are written. Do not continue to any later step. Wait for the human to review and approve the documentation. The human may revise it, and every revision must be reflected as a revision to the remaining plan steps in this file before implementation continues.

### Phase A: Hello World prototype

The goal is the smallest project that shows an HTML page, TypeScript and a Zig function working on every platform. It contains no Photosphere logic. Everything built here is kept and grown by later phases, so build it in the final layout.

Phase A also proves every part of the design that could fail later, so that no later phase has to stop. Each of these is built as a small working piece of the prototype, on each platform it applies to, and its outcome is reported at the Phase A hand-off in step 9:
- A desktop shell in Zig on Windows (WebView2) and Linux (WebKitGTK), with the approved fallbacks of C++ on Windows and C on Linux used only if Zig cannot do it; the MacOS shell is Swift.
- The Zig static library linked into the iOS app and built with Xcode 14.2 on macOS 12.7.6.
- Zig calling the bundled mobile ImageMagick and FFmpegKit libraries (a trivial call such as printing a version) on Android and iOS, using the existing fetch and build scripts.
- The Zig loopback HTTP server reachable from each platform's web view, including cleartext loopback on Android and iOS, answering one request.
- The task machinery, built small and tested on every platform as described in steps 3, 4 and 8: short and long background tasks, progress messages from Zig to the page, cancellation by source, concurrent tasks, and a clean shutdown with tasks still running. The same machinery is grown into the full task runner in Phase B, so it is built the way Phase B needs it, not as a throwaway.
- What happens to a running long task when the app moves to the background and returns on Android and iOS, and when the window is closed on desktop. Record the observed behaviour; background execution itself is built in Phase G.
- Messages at the edges: a large payload (several megabytes of JSON) in each direction, text with quotes, newlines and non-ASCII characters, a flood of progress messages from several threads without loss or reordering within one task, and a Zig error or panic-free failure path that replies with an error instead of crashing the app.
- Zig reading and writing a file in the app's private data directory on each platform, using the platform's storage location passed in by the shell.
- The AWS SDK build and the keychain code from the existing Zig packages linking into the core library on each platform.

2. Create the project skeleton under `apps/photosphere` as a Bun workspace package named `ziggy` (it matches the existing `apps/*` workspace glob; the name `photosphere` is already taken by `apps/desktop`). Layout:
   - `apps/photosphere/package.json` and `tsconfig.json` (the READMEs were drafted in step 1).
   - `apps/photosphere/core/`: the Zig library (`build.zig`, `build.zig.zon`, `src/lib`, `src/test`). `minimum_zig_version` matches `mise.toml`. Depend on existing `packages-zig/*` by relative path only when a phase needs them.
   - `apps/photosphere/ui/`: the TypeScript and HTML for the web view (`index.html`, `src/`, Vite config).
   - `apps/photosphere/shells/windows`, `shells/macos`, `shells/linux`, `shells/android`, `shells/ios`: one native shell per platform.
   - `apps/photosphere/scripts/`: build and run scripts (shell), each with a markdown file beside it.
   - Add `apps/photosphere` to `what-changed.yaml` as the watched paths of new targets (named in step 28) and keep `bun run compile` covering its TypeScript.

3. Write the Zig core library for Hello World in `apps/photosphere/core/src/lib`:
   - A C ABI surface in `ziggy-api.zig`, exported for static and shared linking: `ziggy_create(callbacks) -> handle`, `ziggy_destroy(handle)`, `ziggy_post_message(handle, json_ptr, json_len)`. A message passed to or from Zig is only valid while the call or callback that carries it is running; the receiver copies it before returning and nothing is ever freed across the boundary. `callbacks` is a struct holding one function pointer that delivers a JSON message from Zig to the shell, plus a user-data pointer the shell supplies. The handle is the only state, so there are no globals.
   - A message dispatcher in `dispatcher.zig` that parses a JSON message of the form `{ "id", "channel", "data" }`, routes by `channel`, and replies with `{ "id", "ok", "data" }` or `{ "id", "ok": false, "error" }`. Unknown channels reply with an error, never silently.
   - One handler for channel `ping` that returns the Zig version string, the target operating system and CPU architecture, and an echo of the payload.
   - A minimal task runner in `task-runner.zig`, the seed of the Phase B runner: a pool of worker threads owned by the handle, a queue with priorities, and these channels. `add-task` takes `{taskType, data, source, taskId, priority}` and returns at once. `cancel-tasks` takes a `source` and cancels every queued or running task from it. Events go to the page through the callback: `task-message` (`{taskId, source, message}`) and `task-completed` (`{taskId, source, status, result or error}` where status is `succeeded`, `failed` or `cancelled`).
   - Pool sizes are settings passed in to `ziggy_create`, never constants inside the runner, and take the existing values: the number of worker threads is the number of CPU cores on desktop (`cpus().length` in `apps/desktop/src/main.ts`) and 5 on mobile (`POOL_SIZE` in the Android and iOS `EnginePool`), and `maxConcurrentChildTasks` is one global limit on the child tasks in flight for any one parent task (the same for every task, not set per task) and is 10 on desktop (`apps/desktop/src/worker.ts`) and 2 on mobile (`mobile-worker-runtime.ts`). The platform layer supplies them. Before writing the child task scheduling, read how the Electron worker pool and `worker.ts` run a child task (in the parent's worker or in the shared pool) and match it; the deadlock rule below holds either way.
   - Two test task types: `hello-short`, which does a small amount of work, sends an output message (`{type: "output", text}`), sends a `job-progress` message and completes; and `hello-long`, which loops for a configurable time in small steps, checks for cancellation at every step, sends an output message with a line of text and a `job-progress` message at every step, and completes. A `job-progress` message has exactly the fields of `IJobProgressMessage` in `packages/task-queue/src/lib/job-progress.ts` (`type`, `job` with `id`, `name` and `cancelSource`, `startedAt`, `progressMessage`), sent the way `sendJobProgress` sends it. Any JSON object a task sends is delivered unchanged as the `message` of a `task-message` event. A third, `hello-fail`, returns an error so the failure path is exercised. These are the only test task types and are the Phase A stand-ins for the real handlers, so they are listed in the "Test hooks" section for approval.
   - Child tasks, mirroring how `import-assets.worker.ts` and `import.ts` use `TaskQueue` (`addTask`, `awaitTask`, `awaitAllTasks`) with the `maxConcurrentChildTasks` limit from the task context: the runner gives a task a context that can queue child tasks, wait for one by id, and wait for all of them. `hello-long` takes a number of children (zero allowed) and, at each step, queues `hello-child` tasks (a further test type that sends an output message, a `job-progress` message under the parent's job id, and completes) so that no more than `maxConcurrentChildTasks` run at once, waits for every one to finish before it completes, and reports each child's completion in its own output. Children run on the same pool as their parent, so the runner must not deadlock when every worker is held by a parent waiting for children: design this explicitly (for example, a waiting parent releases its worker slot while it waits, or the pool always keeps capacity for children) and prove it with a test. Cancelling the parent's source cancels its children, and a failed child makes `awaitTask` return its failure to the parent rather than hiding it.
   - The callback can be invoked from any worker thread, so each shell must deliver the message to the web view on the UI thread; the core never assumes which thread calls it.
   - `ziggy_destroy` cancels every running task, waits for the workers to stop, and releases everything, with no task running after it returns.
   - Build outputs from `build.zig`: a static library per target, a shared library for Android, and a C header `ziggy.h` generated or hand-maintained beside the API file so each shell includes the same declaration.

4. Write the TypeScript side in `apps/photosphere/ui/src`:
   - `ziggy-bridge.ts` declaring an `IZiggyBridge` interface (`invoke(channel, data)`, `send(channel, data)`, `onMessage(channel, callback)`, `removeAllListeners(channel)`), the same surface as the existing `IElectronAPI` in `apps/desktop-frontend/src/lib/electron-ipc.ts`, plus the global `window.ziggy` declaration. Each shell injects the native half before page scripts run.
   - `main.ts` that calls `ziggy.invoke("ping", ...)` on load and writes the result into the page.
   - Page controls that start a short task, start a long task with a chosen number of child tasks, start several long tasks at once, cancel by source, and send a large payload, with an output area that shows the text of each output message as it arrives, a job list that shows each job's name and latest progress message, and an event log that lists every `task-message` and `task-completed` event. A plain function in `src/lib/` keeps a running list of jobs from the `job-progress` messages and drops a job when the last task carrying its id completes, as the real frontend does, with a unit test.
   - `index.html` with a heading and an element that shows the reply.
   - A plain function in `src/lib/` that formats the reply for display, with a unit test.
   - A Vite build that outputs to `apps/photosphere/ui/dist`, using relative asset paths (`base: "./"`) as `apps/desktop-frontend` does.

5. Write the shells. Each shell does only these things: create a window or screen with the system web view, inject the `window.ziggy` script before the page loads, load `ui/dist/index.html` from the app bundle, call `ziggy_create`, forward `window.ziggy.invoke/send` calls to `ziggy_post_message`, and forward callback messages from Zig back to the page. Research each web view API from its vendor documentation before writing code, and record the findings (the exact API names used and how the injected script and the message handler are registered) in `apps/photosphere/shells/<platform>/README.md`.
   - Linux (`shells/linux`): a Zig executable linking WebKitGTK and GTK through their C headers. Use a `WebKitUserContentManager` script message handler for page to native and `webkit_web_view_evaluate_javascript` for native to page. If that cannot be made to work, write the shell in C instead (approved), keeping it to the shell duties listed above.
   - Windows (`shells/windows`): a Zig executable hosting WebView2. Find whether WebView2's C-compatible COM headers can be used from Zig through `translate-c`. If they cannot, write the shell in C++ instead (approved), keeping it to the shell duties listed above.
   - MacOS (`shells/macos`): a Swift app with `WKWebView`, a `WKScriptMessageHandler` and a `WKUserScript` for the injected bridge, linking the Zig static library through a bridging header including `ziggy.h`, with the menu, dialogs and drag and drop it needs from AppKit.
   - Android (`shells/android`): a Java `Activity` with a `WebView`, `addJavascriptInterface` for page to native and `evaluateJavascript` for native to page, and a JNI loader for the Zig shared library. Follow the layout of the existing `apps/android-frontend/android` Gradle project (same minimum SDK, target SDK, NDK and CMake handling) and keep the Java to the bridge only. The JNI entry points are written in Zig inside the core library.
   - iOS (`shells/ios`): a Swift app with `WKWebView`, a `WKScriptMessageHandler` and a `WKUserScript` for the injected bridge, linking the Zig static library through a bridging header including `ziggy.h`. The project must build with Xcode 14.2 on macOS 12.7.6. Do not raise any version.

6. Write the build and run scripts in `apps/photosphere/scripts/` (each with a markdown file), exposed as `package.json` scripts in `apps/photosphere` and mirrored in the root `package.json`:
   - Follow the pattern of the scripts the existing `apps/android-frontend` and `apps/ios-frontend` packages have (`setup`, `bundle`, `sync`, `open`, `run`, `clean`, `test:unit`), reusing their helper scripts where they apply (`scripts/install-android-sdk.sh`, `scripts/fetch-mobile-media-tools.sh`, the Android environment script). One script file per job, named `<job>-<platform>.sh` or `<job>.sh`, each called from a `package.json` script of the same name in `apps/photosphere` and mirrored in the root `package.json` as the existing `build:and`, `open:and` and `open:ios` are.
   - `setup` (per platform where needed): installs what the platform build needs, reusing the existing Android SDK and iOS setup scripts. Windows and Linux need nothing beyond `mise install`.
   - `bundle:ui`: the Vite build into `ui/dist`.
   - `bundle:core -- <target>`: `zig build` for one target.
   - `sync:android`, `sync:ios`, `sync:macos`: the equivalent of `cap sync`. Build the core library and the UI for the target, then copy them into the native project (the Zig library into the Android `jniLibs` and the iOS and MacOS project, the UI into the Android assets and the iOS and MacOS bundle resources), so the native project is current when it is opened in an IDE or built by Gradle or `xcodebuild`. Windows and Linux have no sync step, because `build.zig` installs the shell, the core and the UI together.
   - `build:windows`, `build:linux`, `build:macos`, `build:android`, `build:ios`: run `sync` where it exists, then produce the platform output (`zig build` for Windows and Linux; Gradle for the Android APK; `xcodebuild` for the iOS and MacOS apps).
   - `run:linux`, `run:windows`, `run:macos`, `run:android`, `run:ios`: build, then launch the app (on an emulator, simulator or device for mobile, using the existing emulator and simulator scripts and rules). Use `scripts/lib/process-control.sh` for any process they start.
   - `open:android` and `open:ios`, and `open:macos`: run `sync`, then open the native project in Android Studio or Xcode. There is no `open` script for Windows and Linux, because they have no IDE project; `build.zig` is the project.
   - `update:android` and `update:ios`: refresh the native project's dependencies only if the project has some that need an explicit refresh (for example resolving the Swift packages with `xcodebuild -resolvePackageDependencies`). Decide this by looking at the actual project; do not add a script that does nothing.
   - `clean`: removes build output for every platform, one file at a time or with the build tools' own clean commands (no recursive delete).
   - Zig cross-compilation: Linux and Windows build from Linux. MacOS and iOS must be built on a Mac (the existing CLI notes that macOS needs the macOS SDK). Android builds from Linux with the NDK. Record in the scripts' markdown which platforms each script runs on.

7. Write the Phase A unit tests and smoke test:
   - Zig unit tests for the dispatcher (a known channel, an unknown channel, malformed JSON, a missing `id`) and for the `ping` handler.
   - Zig unit tests for the task runner: a short task completes with `succeeded` after sending its output and progress messages; a long task sends its output and `job-progress` messages in order, each serialised with exactly the fields above, and then completes; cancelling a running long task stops it early and completes it as `cancelled`; cancelling a queued task means it never starts; cancel by one source leaves another source's tasks running; several long tasks run at the same time up to the pool size and the rest wait their turn; a higher priority task starts before a lower priority one that was queued earlier; a failing task completes as `failed` with its error; a cancel for an unknown source is harmless; `ziggy_destroy` with tasks still running cancels them, waits and leaves no leak (testing allocator) and no thread; messages sent from several worker threads at once all arrive, in order within each task, none lost.
   - Zig unit tests for child tasks: a parent queues several children and `awaitAllTasks` returns only after all have completed; `awaitTask` returns the result of one specific child; no more than `maxConcurrentChildTasks` children run at once; children of two different parents do not exceed the pool between them; a parent that queues more children than the pool has workers still completes (no deadlock) when every worker is held by a parent; cancelling the parent's source cancels queued and running children and the parent completes as `cancelled`; a failed child is reported to the waiting parent as a failure; a parent with zero children completes normally; progress messages from children carry the parent's job id and drop the job only when the last task with that id completes.
   - Zig unit tests for the edges: a multi-megabyte payload round trips unchanged, text with quotes, newlines and non-ASCII characters round trips unchanged, an invalid or hostile message gets an error reply and the core keeps working, and reading and writing a file under a given data directory works and reports a missing directory as an error.
   - TypeScript unit test for the reply formatter.
   - A Phase A smoke test in `apps/photosphere-smoke-tests` (created here with the minimum needed, grown in Phase I): launches the Linux shell with a free port or a display as needed, waits until the page shows the Zig reply, then drives the task controls: starts a short task and sees its output text, its progress message and its completion shown in the page, starts a long task that spawns children and waits for them and sees output lines and progress messages from the parent and the children arrive and be displayed while the page stays responsive, cancels it and sees it complete as cancelled, starts several long tasks and cancels one source leaving the others running, sends the large payload, and exits with no process left running. The same scenario is repeated on the Android emulator and the iOS simulator, and on Windows and MacOS where a machine is available, with the platforms that could not run it reported at the hand-off. If it needs a hook in the app to learn that the page rendered, it uses only a hook approved in step 1.

8. Add a CI job for the Phase A prototype to `.github/workflows/release.yml` for each platform (Linux, Windows, MacOS, Android build, iOS build) that builds the prototype and runs whatever can run headless. Reuse the existing composite actions and the Zig cache setup used by `build-zig-linux-x64`.

9. STOP at the end of Phase A. Report to the human, in a short summary: what was built, the result of each proof listed at the start of Phase A, which platforms were built and run in this session and which were only built, and which parts are unverified. The human will run the prototype on the platforms the agent could not run. Do not start Phase B until the human says to continue. Any problems found on a platform are fixed in Phase A before moving on, and a platform that cannot work with the chosen approach goes back to the human for a decision.

### Phase B: Bridge protocol and runtime in Zig

10. Define the full message protocol in `apps/photosphere/core/src/lib/protocol.zig`, derived from the existing apps rather than invented:
   - Request channels (answer expected): every `ipcMain.handle` channel in `apps/desktop/src/main.ts` (database, secrets, config, state, pickers, `open-path`, `save-asset`, `save-assets`, `list-s3-dirs`, `import-share-payload`, `check-tools`, `get-log-details`, `mark-update-shown`, `mark-news-shown`, and the rest).
   - One-way channels: `add-task`, `cancel-tasks`, `main-command` (named actions only, as today), `notify-database-edited`, `renderer-log`, `fps-measurement`.
   - Events from Zig to the page: `task-message`, `task-completed`, `platform-event`, `navigate`, `theme-changed`, `database-opened`, `database-closed`, `databases-changed`, `sync-started`, `sync-completed`, `show-notification`, `update-available`.
   - Mobile-only requests, taken from the `JsEngine` plugin interface in `packages/mobile-frontend/src/lib/js-engine-plugin.ts`: `requestMediaPermission`, `exportFile`, `exportFiles`, `startBackgroundImport`, `stopBackgroundImport`, and the secure store calls. Reuse the desktop channel names wherever a desktop channel already does the same job (for example `pick-files`).
   - Write the channel list into the "Protocol" section of `docs/ziggy-architecture.md` with the payload of each channel taken by reading the TypeScript that sends and receives it. Do not guess a payload.

11. Port the message dispatch in `apps/photosphere/core/src/lib/`, one Zig file per `ipcMain` handler group in `apps/desktop/src/main.ts`, keeping the handler order and logic. Handlers that call into ported packages call them directly. Handlers whose logic is currently TypeScript-only (`app-config`, `app-state`, `databases-config` workers) are covered in Phase E.

12. Port the task runner. The TypeScript original is `WorkerPoolElectronMain` (`apps/desktop/src/lib/worker-pool-electron-main.ts`) and the `packages/task-queue` queue classes, with `packages-zig/task-queue-zig` as the base. In Zig, the runner executes the task handlers on a pool of threads inside the core library (no child processes and no embedded JavaScript engine), keeps the same priorities, the same cancellation by source, the same pool size and child task limit per platform (set by the platform layer as in step 3, never hard-coded in the runner), and sends `task-message` and `task-completed` events through the callback. Job reporting follows the repository rule: handlers send `IJobTag` data through `sendJobProgress` unchanged, and nothing in Zig keeps job state.

### Phase C: Asset HTTP server in Zig

13. Port `packages/node-api/src/lib/asset-server-routes.ts`, `asset-server-core.ts` and `packages/rest-api/src/lib/asset-server.ts` to a new `packages-zig/rest-api-zig` and the matching files in `packages-zig/node-api-zig`. The server binds `127.0.0.1` on a port chosen by the operating system, serves exactly `GET /asset?id&db&type`, `POST /asset` and `POST /apply-database-ops` with the same status codes, headers (including the CORS header the original sends) and range behaviour, and reports the bound port to the page through the same `asset-server-ready` message and `restApiUrl` query parameter the existing apps use. Use a maintained Zig or C HTTP library only if one is required; otherwise use the Zig standard library. Do not hand-write anything that a maintained library already does for this (TLS is not involved on loopback). If a library is needed, the library rule in the ground rules applies.

14. Make Android and iOS allow cleartext loopback to the asset server the same way the existing apps do (`network_security_config.xml` on Android; the iOS App Transport Security setting in `Info.plist`), after reading how the existing apps configure it.

### Phase D: Wire the existing user interface to Ziggy

15. Find the minimum UI change set by reading how `apps/desktop-frontend/src` and `packages/mobile-frontend/src` plug into `packages/user-interface`. Record the result in the "UI changes" section of `docs/ziggy-architecture.md` before changing anything: each file, what must differ, and why `packages/user-interface` itself must change (expected: nothing, because it is configured through `IPlatformContext`, `IQueueBackend` and the providers).

16. In `apps/photosphere/ui/src`, add the Ziggy platform layer, copying from `apps/desktop-frontend` and extending with the mobile members from `PlatformProviderMobile`:
   - `ziggy-queue-backend.ts`: an `IQueueBackend` that proxies over `window.ziggy`, copied from `ElectronRendererQueueBackend`.
   - `platform-provider-ziggy.tsx`: an `IPlatformContext` built on `window.ziggy`, copied from `platform-provider-electron.tsx`. Members that differ by platform (database picker, drag-drop import, background import, network status, media permission) are driven by a `platformKind` value (`desktop` or `mobile`) that the shell reports through the `ping`-style `get-platform` request, not by user-agent sniffing.
   - `app.tsx` and `main.tsx`: the entry, taken from `apps/desktop-frontend/src/app.tsx`, reading `restApiUrl`, `theme` and the test-mode flag from the query string as today.
   - Pure logic stays in `src/lib/` functions with unit tests. Components, contexts and hooks get no unit tests.

17. Make the UI build output a Ziggy bundle: `ui/dist` is copied into each shell by the build scripts. Check at phone width using `bun run stories:and` and the stories player equivalent for Ziggy added in Phase I.

### Phase E: Port the remaining non-UI TypeScript to Zig

Work from the inventory of `packages/node-api/src/lib`, `packages/api`, `packages/task-queue`, `packages/lan-share-network`, `packages/vault` and `apps/desktop/src`. For each item: read the TypeScript, write the Zig beside the existing Zig package, add the unit tests, add the function-by-function entry in `docs/zig-port-map.md`, and tick the item in the feature checklist (step 29). Check the current state of each package with `git grep` and a directory listing before starting it, because ports land in other work and the lists below were taken from a survey, not a guarantee.

18. Task handlers in `packages/node-api/src/lib/task-handlers.ts` that have no Zig handler yet. Register each in `packages-zig/node-api-zig/src/lib/task-handlers.zig` with the same task type string: `test-job`, `load-assets`, `sync-database`, `save-asset`, `save-assets-batch`, `create-database`, `create-default-database`, `get-database-summary`, `get-import-record`, `set-database-origin`, `move-assets`, `asset-server`, `receive-share`, `find-receiver`, `send-payload`, `check-database-exists`, `evict-originals`, `reset-app-storage`, plus the mobile planning handlers (`plan-auto-import`, `plan-sync`, `plan-prefetch`) and anything else registered in `mobile-worker-entry.ts` or `task-handlers.ts` that a directory listing finds and this list misses. One file per `.worker.ts`, named after it.

19. Non-handler modules in `packages/node-api/src/lib` with no Zig counterpart: `apply-database-ops.ts`, `app-config.ts` and `app-config-format.ts`, `app-state.ts` and `app-state-format.ts`, `config-file.ts`, `config-format.ts`, `auto-import-desktop.ts`, `auto-import-queue.ts`, `zip-utils.ts`, `database-cache-dir.ts`, and the config, state and databases-config workers. Port `sync.ts` fully (its worker was missing). Confirm each is still missing before porting.

20. `packages/api` pieces without a Zig counterpart (the sync permission check, write lock, auto-import types) and the `packages/config` constants, checked against `packages-zig/api-zig` and `apps/cli-zig/src/lib/config.zig`.

21. The `apps/desktop/src` main-process logic that is not Electron API calls, ported into `apps/photosphere/core/src/lib` with the same file names where practical: `checkForUpdate`, `checkForNews`, the sync scheduling (debounce after an edit and the periodic sync, both controlled by `set-sync-allowed`, as in `apps/dev-server/src/index.ts` and `main.ts`), the single-instance rule, the database open and close notifications, the file logger, the log details request, and the desktop MCP server (`apps/desktop/src/lib/mcp/`, including the three tools the CLI does not have: `delete-media-file`, `open-media-file`, `update-media-file`). The MCP server keeps its fixed port and its `POST/GET /mcp` routes, since those are existing usage; extend `apps/cli-zig/src/lib/mcp` rather than writing a second implementation.

22. Mobile-side logic currently in `packages/mobile-frontend` and `packages/mobile-worker` that is not an adapter for the embedded engine: `background-work.ts` scheduling decisions, `mobile-media-cleanup.ts`, `mobile-share-receive.ts`, and the config, state and databases-list file handling. Port what has logic into the core. The embedded JS engine, the Node shims (`packages/mobile-worker/src/shims`) and the `host.*` functions are not ported: their jobs are done by Zig calling the real operating system directly.

23. Check whether any behaviour is lost by dropping the dev server: `apps/dev-server` is not delivered, so do not port it. Confirm the web-only developer loop still works by listing what `bun run dev:web` needs, and leave it alone.

### Phase F: Desktop platform features

24. Implement in each desktop shell, on top of the message protocol (a platform feature is only native code when the operating system forces it, everything else is in Zig). Keep the native code per feature as small as the operating system allows and put the shared decision logic in Zig:
   - Window creation with the `-geometry=WxH+X+Y` command line option, and the window title.
   - Application menu with the same items as `createMenu()` in `apps/desktop/src/main.ts` (File, View, Preferences with theme, Window, Help, plus the macOS app menu), sending `platform-event` menu actions and `navigate`. Menu content comes from Zig so it is defined once.
   - Native file, folder and save dialogs for `pick-file`, `pick-files`, `pick-folder` and the save dialog used by `save-asset`.
   - `open-path` and opening external links with the system handler, and sending any non-app navigation out to the system browser.
   - Drag and drop of files into the window, returning file paths to `getPathForFile`.
   - Developer tools toggle through the `main-command` channel's existing `toggle-devtools` action.
   - Single-instance behaviour.
   - OS keychain access: the vault packages already contain the Windows, MacOS and Linux keychains in Zig (`packages-zig/vault-zig`), so the shell does nothing for them.
   - Packaging that produces the same artifact kinds the Electron build produces today (check `electron-builder` settings in `apps/desktop/package.json`: installer and zip for Windows, dmg and zip for MacOS, deb and zip for Linux), written as scripts with markdown beside them. Signing and notarisation are not done; record in the scripts' markdown that they are not.

### Phase G: Mobile platform features

25. Implement in the Android and iOS shells only what the operating system forces, exposed to Zig as a small set of host callbacks that are registered in `ziggy_create` and used by the core (so there are no globals). Port the behaviour from `apps/android-frontend/android/app/src/main/java/.../jsengine` and `apps/ios-frontend/ios/App/App/JsEngine`, not the engine plumbing:
   - Photo library listing, albums, opening, closing and the system delete request, with the permission flow including the partial permission answer on Android 14 and later, and PhotoKit on iOS.
   - File and folder pickers (`ACTION_OPEN_DOCUMENT` on Android, `PHPicker` on iOS) copying picked items into the sandbox.
   - Export and share (`ACTION_CREATE_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`, `UIActivityViewController`) with temp copies removed on every exit.
   - Secure storage for secrets (EncryptedSharedPreferences on Android, Keychain on iOS).
   - Background work: the Android foreground service of type `dataSync` and the three iOS `BGTaskScheduler` tasks (auto-import, background-sync, background-prefetch), each starting a core task and nothing else.
   - Network type and change notifications.
   - Android and iOS permission strings, manifest entries and `Info.plist` entries already used by the existing apps.
   Everything else the old plugins did (crypto, sockets, files, hashing, TLS, UDP) is done in Zig and is not rewritten in Java or Swift.

26. Media tools. Desktop keeps using external `magick`, `ffmpeg` and `ffprobe` through the ported `tools-zig` with the same tool check. For mobile, the existing apps link ImageMagick and FFmpegKit in process. Determine, by building, how the core calls the same prebuilt libraries (Android shared libraries per ABI, iOS static libraries) from Zig through their C interfaces. Use the existing fetch and build scripts (`scripts/fetch-mobile-media-tools.sh`, `apps/ios-frontend/ios/build-imagemagick.sh`) rather than new ones. If FFmpegKit cannot be called from Zig, the library rule in the ground rules applies; do not write a replacement.

### Phase H: Remaining desktop-only and mobile-only behaviours

27. Cover what the survey found outside the channels above: LAN share (`receive-share`, `find-receiver`, `send-payload`) over the ported `lan-share-network-zig` with UDP and TLS on all five platforms, the news and update notifications, the secrets screens through the vault, the sync settings, the developer screen, the reset-device flows, and the auto-import flows on both desktop and mobile. For each, run the matching old smoke test scenario against Ziggy once Phase I has ported it, and fix differences.

### Phase I: Consolidated smoke tests

28. Create `apps/photosphere-smoke-tests` (Bun workspace package `ziggy-smoke-tests`), a new project that holds one set of smoke tests for Ziggy on every platform, consolidating `apps/desktop/smoke-tests` and `apps/smoke-tests/tests`:
   - One directory per scenario with a `test.sh`, keeping the existing naming (`<n>-<name>/test.sh`) and the existing exit code 77 for a skip. Merge duplicates between the two sets: scenarios that exist in both (create-database, open-database, import-photos, secrets, share, S3, replicate, move-file, download, reset-device, auto-import, and so on) become one platform-neutral test that runs on desktop and mobile, with a platform check only where behaviour truly differs. Scenarios that exist on one side only (for example the mobile background import and sync tests, and the desktop developer screen test) keep that restriction. Each Ziggy scenario directory name keeps the old scenario name so the audit can match them by listing both sides.
   - Reuse the existing runner library and pools: `apps/smoke-tests/lib/runner.sh`, `scripts/lib/test-pool.sh`, `test-timeout.sh`, `test-concurrency.sh`, `process-control.sh`, `test-lib.sh`, and the Android emulator pool commands and rules. Do not copy them; reference them. Do not add marker files.
   - Driving the app: use the same mechanism as today (host-side control bridge plus the shared `test-driver.ts` in the page) once the human has approved the Ziggy test hooks (see ground rules). Drive Android with `adb` and iOS with `xcrun simctl` as the existing libraries do.
   - Register the suites: root `package.json` scripts `test:ziggy` (desktop, runs on the host OS), `test:ziggy:and` and `test:ziggy:ios`, each ending in `what-changed baseline capture <name>`; matching `targets` in `what-changed.yaml` with the right `platforms`; and entries in `scripts/test-everything-parallel.sh` (with `SERIAL_GROUPS` only if a shared build directory forces it). Run `bun run test:parallel` to prove no suite contends with another.
   - Add a Ziggy stories run (`stories:ziggy`) reusing the existing story player so phone-width checks work on Ziggy.
   - Add the Zig unit tests (`zig build test` in `apps/photosphere/core`) to the unit-test target that runs for the other Zig packages, and add the CI jobs for the Ziggy suites to `.github/workflows/release.yml` as dependencies of `create-release`.
   - Every ported behaviour needs an end-to-end check somewhere in these suites or the existing `psi` smoke suites; list the coverage of each checklist item in the checklist.

### Phase J: Parity check

29. Maintain the feature checklist below in this plan file as work proceeds. Each item is ticked only when the Ziggy implementation exists, its unit tests pass, and a smoke test covering it passes on every platform the item applies to. Where a platform is not run in this session, write what was not run next to the item.

   Core and shared:
   - [ ] Message bridge on all five platforms
   - [ ] Task runner: priorities, cancellation by source, child tasks, progress events
   - [ ] Job reporting through `IJobTag` and `sendJobProgress`
   - [ ] Asset server: `GET /asset`, `POST /asset`, `POST /apply-database-ops`
   - [ ] Config, state and databases list
   - [ ] Secrets and vaults (OS keychains, plaintext vault)
   - [ ] Every task handler registered in `task-handlers.ts`
   - [ ] Create, open, close, remove, find and set-origin of databases
   - [ ] Import (files, folders, mobile photo library), including cancel and video
   - [ ] Auto-import, background import and background sync and prefetch
   - [ ] Sync, replicate, consolidate, verify, check, prefetch, evict originals, move assets
   - [ ] Encrypted databases and S3 databases (local S3 server as in the existing S3 suites)
   - [ ] Edit asset metadata and photo date
   - [ ] Export, download, save assets
   - [ ] LAN share of secrets and databases, send and receive, cancel and timeout
   - [ ] News and update notifications
   - [ ] Reset device (local, S3, failure)
   - [ ] Sync settings and developer screen
   - [ ] Reopen last database, stale recent database, remove recent database

   Desktop (Windows, MacOS, Linux):
   - [ ] Menus, pickers, open path, external links, drag and drop, devtools toggle
   - [ ] Single instance, geometry option
   - [ ] Desktop MCP server including the three desktop-only tools
   - [ ] External media tools check
   - [ ] Packaged artifacts matching the Electron artifact kinds

   Mobile (Android, iOS):
   - [ ] Photo library access, partial permission, delete request
   - [ ] File pickers, export and share
   - [ ] Secure storage
   - [ ] Foreground service (Android) and background tasks (iOS)
   - [ ] Bundled ImageMagick and ffmpeg
   - [ ] Phone-width layout of every page

### Phase K: Final audit

Run after every other phase is finished. The audit is read-only except for fixing what it finds. Report each result to the human in the final message (what was checked, how, what was found, what was fixed); no audit file is written. Any finding is fixed properly and the check is run again; a finding is never recorded and left.

30. Faithful port audit, including compatibility with the Electron and Capacitor standards named in the ground rules (names, payloads, task types, layout, style). List every Zig file added or changed by this work that ports TypeScript (use `docs/zig-port-map.md` and `git diff --stat` against the start of the work). For each, open the TypeScript original beside the Zig and compare: same functions in the same order, same control flow, same conditions and constants, same error cases and messages, same edge-case handling. Differences forced by Zig are acceptable only when commented above the function and recorded in the port map. Check the Zig tests carry over the cases of the TypeScript tests. Fix any divergence in the Zig to match the TypeScript.

31. Coverage audit. Run the Zig coverage tooling described in `docs/zig-test-coverage.md` over `apps/photosphere/core` and every Zig package touched. List every function without a unit test and every branch left uncovered, and add tests for them (each watched failing first). Run the TypeScript coverage for the pure functions in `apps/photosphere/ui/src/lib`. React components, contexts and hooks are excluded and must instead be covered by a smoke test.

32. Smoke test audit. Check that every scenario directory in `apps/desktop/smoke-tests` and `apps/smoke-tests/tests` (the manual one included, marked as manual) has a Ziggy equivalent, by listing both directories at audit time and comparing; do not rely on a remembered list. Then run every Ziggy suite on every platform it applies to (desktop on the host, `test:ziggy:and`, `test:ziggy:ios` where available) and confirm all pass, with a platform that was not run reported as not run. Run `bun run test:parallel` and `bun run tev`.

33. No-hacks audit. Search everything added or changed for the following and remove or properly fix each one found:
   - Test-only scaffolding in the shipped app (test drivers, seeding functions, injection points, test-only commands, events or globals, test mode switches) other than hooks the human explicitly approved, each of which must be named in the audit report together with where the human approved it.
   - Mocks, fakes, stubs or hand-written replacements of a third-party SDK or library, and build-time aliasing of a real package.
   - Silent no-ops, swallowed errors, success values returned when the work did not happen, skipped or loosened tests, tests that cannot fail, marker files, TODO comments about known bugs.
   - Workarounds for a bug instead of a fix, scripts that exist to serve the agent's own harness, globals, embedded languages in shell scripts, other languages than the allowed ones.
   - Any edit to existing UI code not recorded in the "UI changes" section of `docs/ziggy-architecture.md`.
   - Anything beyond what the checklist needs (see the note on overreach).
   Report the result of each search in the audit report, including searches that found nothing and the exact command used.

### Final step

34. Update every document drafted in step 1 so it matches what was built (remove every "to be confirmed in Phase A" note, mark each ported function in `docs/zig-port-map.md` as ported, and bring each file to its final state). The files are:
   - `docs/ziggy-architecture.md`, the one new document, with these sections: the architecture (core library, shells, message bridge, asset server) and the rules for adding a channel or a native host callback; "Protocol" (every channel and event with its payload, started in step 10 and brought to its final state); "UI changes" (every edit to existing UI code from step 15, with the reason); and the rule that platform code stays out of `packages/user-interface`.
   - `apps/photosphere/README.md`: what Ziggy is for, the directory layout, how to build and run it on each platform, and which platform each script runs on.
   - `apps/photosphere/shells/<platform>/README.md` for each shell: what the shell does, which web view API it uses, and how its build works.
   - `apps/photosphere-smoke-tests/README.md`: how to run the suites and how scenarios are named and organised.
   - `docs/zig-port-map.md`: every function ported in Phase E.
   - `docs/testing/README.md` and root `CLAUDE.md` (Commands and Guides sections): the new `test:ziggy*` scripts and the link to the new guide. Do not mention plans anywhere in these files.
   - Markdown beside each new script.

## Unit Tests

Zig, in `apps/photosphere/core/src/test` and in the existing Zig packages that gain code (`zig build test`, with each test watched failing first):
- `dispatcher`: routes a known channel, rejects an unknown channel, rejects malformed JSON, rejects a missing `id`, returns an error reply when a handler fails.
- `ping` handler: reply contents.
- Origin check (`origin-check.zig`): the app's own bundled address is allowed, any other `file://` path, `http://` and `https://` address, and a malformed address are refused, and external links are reported as "open in system browser".
- `ziggy-api`: create then destroy releases everything (use the testing allocator's leak detection), a message posted after destroy is rejected, the callback receives the reply.
- `protocol`: each channel's request and reply parse and serialise round trip, taken from the sample payloads read from the TypeScript.
- Task runner: priority order, cancel by source, child task limit, completion and message events, handler failure becomes a failed completion event.
- Asset server routes: each route's status codes, headers and range handling, copied case by case from the tests of `asset-server-routes.ts`.
- Every ported function in Phase E, with the test cases carried over from the matching TypeScript tests in `packages/*/src/test` (same inputs, same expected outputs).
- Main-process logic ported in step 21: update check parsing, news check parsing, sync debounce and periodic timing (with an injected clock), menu definition content, MCP tool request handling.
- Android: Gradle unit tests for the Java bridge and the host callback adapters, following the existing `src/test/java` layout.
- iOS: XCTest tests for the Swift bridge and host callback adapters, following `AppTests`.
- TypeScript, in `apps/photosphere/ui/src/test`: the reply formatter, and every pure function in `src/lib/` (for example the mapping from `platformKind` to platform capabilities). React components, contexts and hooks are not unit tested.

## Smoke Tests

- Phase A: the Linux prototype shows the Zig reply in the page (see step 7), run in CI on the other platforms as build-only checks, plus a launch check wherever a headless runner exists.
- Ziggy desktop suite (`test:ziggy`) and mobile suites (`test:ziggy:and`, `test:ziggy:ios`) in `apps/photosphere-smoke-tests`, so every scenario of the existing Electron and mobile suites has a Ziggy equivalent.
- Asset server: image, thumbnail, display and video requests, a write through `POST /asset`, and `POST /apply-database-ops`, exercised through the app's pages (import photos, view photo, edit metadata) and checked with the existing `psi verify` on the resulting database.
- Interop: databases written by Ziggy are checked with the TypeScript `psi verify` and the Zig `psi verify`, and databases written by `psi` open in Ziggy.
- CLI to Ziggy LAN share (both directions), replacing the CLI to desktop suite once the Electron app is gone (that removal is out of scope here).
- Stories run on Ziggy at phone width.
- `bun run test:parallel` run with the new suites included, to prove they survive beside each other and beside every existing suite.
- The full `bun run tev` run before finishing.

## Verify

- `bun run compile` passes, covering the TypeScript of `apps/photosphere` and `apps/photosphere-smoke-tests`.
- `zig build` for the core succeeds for every target built from the current machine, and the platform builds that need a Mac (MacOS, iOS) are built there or reported as not verified.
- `zig build test` passes for `apps/photosphere/core` and for every Zig package touched; every new test was seen failing before it passed.
- `bun run test` passes (TypeScript unit tests).
- `bun run test:ziggy` passes on the host, and `test:ziggy:and` and `test:ziggy:ios` pass wherever the emulator or simulator is available; check the Android pool with `bun run emu:and:pool:status` at the moment it is needed.
- `bun run test:parallel` reports no failures in company.
- `bun run tev` passes, plain, without `--force`.
- The feature checklist in step 29 has every item ticked, or a written note of what was not run and why.
- `git diff` against the start of this work, limited to `packages/user-interface`, `apps/desktop-frontend`, `apps/dev-frontend`, `packages/mobile-frontend` and the other existing frontends, shows only the edits listed in the "UI changes" section of `docs/ziggy-architecture.md`.
- `rg` finds no em dash, no mention of a plan, no machine-specific absolute path, no hard-coded count and no ticket number in any file added by this work.

## Notes

- The human expects no hacks and no workarounds: everything is done properly, the first time, at the cause. The human equally does not want over-engineering or overreach: build what the feature checklist needs and nothing more, no extra framework features, no generality for other apps, no abstractions with a single user. Phase K audits both.
- Compatibility with the existing Electron and Capacitor projects is a requirement, not a preference: Ziggy follows their standards and names wherever it can (see the ground rules), and Phase K checks it as part of the faithful port and no-hacks audits.

- The previous plan the human mentioned was not shown, so this plan was built from the code. The files `docs/plans/new/plan-zig-core-port.md` and `plan-zig-cli-port.md` are different work (a port into a new repository) and were not used.
- The bridge follows the existing apps instead of inventing a protocol: Electron's `invoke/send/onMessage` surface and channel names, and the mobile `JsEngine` plugin methods, with the same three HTTP routes for media. The asset server is already shared between desktop and mobile in TypeScript, so one Zig port covers both.
- Linux is a delivered desktop target, as the human decided, in addition to Windows, MacOS, Android and iOS.
- The desktop shells: MacOS is Swift. Windows and Linux are Zig first, with C++ and C as approved fallbacks if Phase A shows Zig cannot host WebView2 or WebKitGTK. Phase A records which was used in the shell READMEs.
- Packages are named `ziggy` (the app, because `photosphere` is the name of `apps/desktop`) and `ziggy-smoke-tests`; the root `apps/*` workspace glob picks both up.
- iOS stays on Capacitor-era tooling constraints: Xcode 14.2 and macOS 12.7.6. Whether Zig 0.16 can produce an iOS static library that links under Xcode 14.2 is a Phase A question, and a negative answer goes to the human.
- Embedded JavaScript engines, the Node shims and the `host.*` bridge are dropped because Zig runs the handlers natively. Only the behaviours behind them are carried over.
- `apps/dev-server` and `apps/dev-frontend` are not ported; they serve the web-only developer loop, not a delivered app.
- Test hooks in the app need explicit human approval before they are written. Until then smoke tests can only use hook-free launch checks.
- Code signing, notarisation and store distribution are out of scope. The existing Android distribution (a debug APK to Firebase App Distribution) is unchanged by this plan.
- Removal of `apps/desktop`, `apps/desktop-frontend`, the Capacitor apps and their smoke tests happens after parity and is not part of this plan.
- The plan stops after step 1 for the human to review the drafted documentation, as the human asked. The other stops are the Phase A hand-off the human asked for, and the places where a rule requires asking first (a library that will not work, an unavoidable non-Zig language, test-only hooks).
