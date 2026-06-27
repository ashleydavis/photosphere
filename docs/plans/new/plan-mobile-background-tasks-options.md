# Mobile Background Tasks: Plan (Embedded JS Engine)

## Issues

Found by `/plan:check`. Check each off as it is addressed.

- [ ] 1. (Missing) Sync/async bridge mismatch: `IQueueBackend.addTask` is synchronous and must return the taskId immediately, but Capacitor plugin calls return Promises. State that `JsEngine.addTask` must be fire-and-forget (id generated locally, like the Electron `send` path) and specify how the un-awaited dispatch promise's rejection is handled.
- [ ] 2. (Missing) Capacitor `addListener` is async (returns `Promise<PluginListenerHandle>`) while Electron registers listeners synchronously. Address the race where `taskCompleted`/`taskMessage` can fire before the listener resolves, and listener-handle cleanup.
- [ ] 3. (Missing) Ownership of `EmbeddedJsQueueBackend` is unspecified: android and ios `mobile-queue-backend.ts` are currently byte-identical duplicates. Decide shared module vs per-app duplication. Same for the location of `mobile-worker-entry.ts`.
- [ ] 4. (Missing) Pool size configuration source is unspecified (build constant vs runtime setting vs device detection).
- [ ] 5. (Missing) `shutdown()` behaviour for the pool/plugin (engine-thread teardown, Capacitor listener removal) is not described.
- [ ] 6. (Missing) `sessionId` ownership on mobile is unspecified; pin which side owns it and how it stays consistent with the WebView session.
- [ ] 7. (Missing) Inventory grep list omits network APIs (`http`/`https`/`net`/`tls`/`fetch`); confirm nothing bundled needs them once storage is replaced by `HostStorage`.
- [ ] 8. (Inconsistency) Components names only the android backend path, but step 8 wires both android and ios `app.tsx`; specify the ios side.
- [ ] 9. (Inconsistency) "reuse the prototype's `build:bundle`/`copy:bundle` scripts" and "`JsRunner` ... reused": the prototype is a separate repo, so these are re-created/ported here, not reused. Reword.
- [ ] 10. (Inconsistency) Worker-entry location named two ways ("packages/api (or a new packages/mobile-worker)"); existing worker entries live under `apps/`. Settle the location.
- [ ] 11. (Issue) Bundle global exposure: rely solely on the entry's manual `globalThis.Worker = { runTask }` assignment under `bun build --format=iife`, and do not also set a bundler global-name, so the two mechanisms cannot collide.
- [ ] 12. (Issue) Global name `Worker` shadows the built-in Web Worker constructor and can collide in the Bun / `quickjs-emscripten` parity harnesses; consider a non-colliding name.
- [ ] 13. (Issue) Whole-file base64 marshalling of bytes across the bridge risks OOM for large assets; consider streaming/file-handle for large blobs beyond the `host.sha256` hashing path.
- [ ] 14. (Issue) Synchronous `isCancelled()`/`sendMessage()` require native sync callables touching a lock-guarded shared set from inside a running task; confirm both engine bindings support this and the lock is safe for a sync mid-task call.
- [ ] 15. (Tests) No native unit test for the pool dispatcher (FIFO order, idle-slot assignment, cancel-drops-pending, concurrency cap, size-1 serial). Add direct dispatcher tests on both platforms.
- [ ] 16. (Tests) No test for the addTask fire-and-forget / dispatch-rejection path, nor the addListener race/cleanup.
- [ ] 17. (Tests) No large-payload base64 round-trip test (the OOM-risk path).
- [ ] 18. (Tests) Cancellation of a pending (not running) task is not a distinct test case.
- [ ] 19. (Docs) `docs/background-tasks.md` is not updated for the mobile/embedded-engine path.
- [ ] 20. (Docs) CLAUDE.md Mobile/Architecture section is not updated to mention the embedded JS engine + host bridge.
- [ ] 21. (Docs) The host-bridge checklist file's repo location is not fixed.
- [ ] 22. (Security) Path traversal: native storage host functions take JS/task-supplied path strings; sandbox to the storage root and reject `..`/absolute paths.
- [ ] 23. (Security) State that `worker.bundle.js` is only ever eval'd from the packaged app asset, never a remote/OTA source.

## How it works (Android and iOS)
The flow is identical on both platforms; only the engine implementation differs (iOS uses JavaScriptCore, Android uses QuickJS).

```mermaid
flowchart TD
    subgraph WV["WebView (shared TypeScript frontend, same on both platforms)"]
        APP["App code<br/>TaskQueue.addTask(type, data)"]
        QB["EmbeddedJsQueueBackend<br/>(IQueueBackend)"]
        APP --> QB
        QB -->|"onTaskComplete / onTaskMessage"| APP
    end

    QB -->|"JsEngine.addTask / cancelTasks"| PLUGIN["JsEngine Capacitor plugin (native)<br/>pending queue + dispatcher<br/>running-task map + cancelled-source set"]
    PLUGIN -->|"notifyListeners: taskCompleted / taskMessage"| QB

    subgraph POOL["Native engine pool (N threads)"]
        E1["Engine thread 1<br/>JS context + worker.bundle.js<br/>Worker.runTask()"]
        EN["Engine thread N<br/>JS context + worker.bundle.js<br/>Worker.runTask()"]
    end

    PLUGIN -->|"dispatch task to idle engine"| E1
    PLUGIN -->|"dispatch task to idle engine"| EN
    E1 -->|"result / streamed messages"| PLUGIN
    EN -->|"result / streamed messages"| PLUGIN

    E1 -->|"host bridge: storage / sha256 / media / sendMessage / isCancelled"| HOST["Native host functions"]
    EN -->|"host bridge"| HOST
    HOST --> FS[("Device storage and OS image/video frameworks")]

    ENGINE["Engine per platform:<br/>iOS = JavaScriptCore, Android = QuickJS"] -.- POOL
```

## Overview
Background tasks on mobile will be implemented by running the existing task handlers as JavaScript inside a JS interpreter embedded in the app's native code, driven from native, off the WebView. This is the approach proven by the standalone `capacitor-embedded-javascript-prototype` repo (a separate project outside this monorepo). This plan records the chosen engines and specifies how the worker code is compiled and packaged for the engine, and how tasks are dispatched into it and results/events flow back to the web app.

The orchestration layer (`packages/task-queue`) stays in TypeScript and is reused. The handlers (`packages/node-api/src/lib/*.worker.ts`) are compiled to a single JS bundle and executed by the embedded engine, with their Node dependencies (`fs`, native tools) replaced by a host bridge into native code. The rest of the app is unchanged: it keeps using `TaskQueue` against an `IQueueBackend`, exactly as on desktop.

## Terminology
- **Task**: a single unit of work with a `type` (for example `hash-file`, `load-assets`, `import-assets`) and input `data`, dispatched through the task queue and run by a registered handler. A task returns a result, can stream progress messages, can be cancelled, and is tagged with a `source` string that groups related tasks. Defined in `packages/task-queue`.
- **Background task**: a task, emphasising that it runs off the UI/main thread in a worker. In this codebase every task is a background task; the terms are used interchangeably for the worker-level unit of work. This plan is about running background tasks on mobile.
- **Task queue** (`TaskQueue` / `IQueueBackend`, `packages/task-queue`): the mechanism that accepts tasks (`addTask`), dispatches them to a backend, and returns results and streamed messages (`awaitTask`, `onTaskComplete`, `onTaskMessage`). `TaskQueue` is the caller-facing API; `IQueueBackend` is the pluggable executor/transport behind it.
- **Worker pool**: an `IQueueBackend` implementation that owns a set of workers (OS threads, processes, or embedded JS engine instances) and runs task handlers across them in parallel. Examples: `WorkerPoolBun` (CLI), `WorkerPoolElectronMain` (desktop), and the mobile engine pool defined by this plan. Proxy backends (`ElectronRendererQueueBackend`, `EmbeddedJsQueueBackend`) forward to a pool that lives elsewhere rather than owning workers themselves.
- **Background job** (`IJob`, the Job Manager, `plan-job-manager.md`): a user-visible background activity shown in the navbar/sidebar with a name, progress, and optional Cancel. A job is higher-level than a task: it represents what the user sees and may aggregate one or more underlying tasks that share a `source`/`sourceTag`. Cancelling a job cancels those tasks via `platform.cancelTasks(sourceTag)`.

## Chosen engines (from the prototype)
The prototype implemented and tested all ranked engine options on device. The picks:
- iOS: JavaScriptCore (prototype branch `engine/ios-javascriptcore`). System framework, no third-party dependency, real `async`/Promise support, JIT. Confirmed working on device.
- Android: QuickJS via the Quack JNI binding (prototype branch `engine/android-quickjs`). Small, real `async`/Promise support. Confirmed working on device.
- Android fallback: Rhino (`engine/android-rhino`) is pure-JVM with no NDK and also worked, but it has no `async`/`await`, so the prototype stripped async to run it. The real handlers are heavily asynchronous, so Rhino is only a fallback for a synchronous-only subset and is not the target. iOS Duktape (`engine/ios-duktape`) is likewise a proven fallback but ES5-only.

Async support is the deciding factor: the handlers use `async`/`await` throughout, and both JavaScriptCore and QuickJS run real promises, so the handlers run unchanged.

## How the prototype maps to this work
The prototype proved the core round trip with a toy task (`levenshtein`). This plan scales that exact mechanism up to the real handlers:
- Prototype `task.bundle.js` (one toy function) becomes `worker.bundle.js` (all handlers plus the task-queue runtime).
- Prototype `host` bridge (`log`, `getInput`) grows into the full host bridge (`log`, `sendMessage`, `isCancelled`, storage, media tools).
- Prototype `JsEngine.runTask` (one-shot) becomes a queue-backed plugin that runs many tasks and streams messages and completion events.
- Prototype `JsRunner` (JSC / QuickJS) implementations are reused as the engine hosts.

## Integration Design

### Components
- Web (WebView, TypeScript): `EmbeddedJsQueueBackend implements IQueueBackend`, replacing the current no-op `MobileQueueBackend` (`apps/android-frontend/src/lib/mobile-queue-backend.ts`). It forwards `addTask` / `cancelTasks` to the native `JsEngine` Capacitor plugin and turns plugin events back into `IQueueBackend` callbacks. This mirrors `ElectronRendererQueueBackend` (`apps/desktop-frontend/src/lib/electron-renderer-queue-backend.ts`), which does the same over Electron IPC.
- Native (`JsEngine` Capacitor plugin, our own code): owns a pool of embedded engine instances (see the concurrency model below), maintains the pending-task queue, a running-task map, and a cancelled-source set, installs the host bridge into each engine, and emits `taskCompleted` / `taskMessage` events to the WebView via Capacitor's `notifyListeners`.
- Embedded JS (`worker.bundle.js`): the compiled handlers plus a thin mobile worker runtime that exposes `globalThis.Worker.runTask(taskId, type, dataJson)`, builds an `ITaskContext` backed by the host bridge, and calls the existing `executeTaskHandler` from the task-queue registry. The same bundle is loaded independently into each engine in the pool.

### Concurrency model: a pool of engine threads (the mobile worker pool)
A single JS engine is single-threaded, so one engine cannot run two CPU-bound tasks at once. To match the desktop behaviour (for example loading assets and importing assets at the same time), the native plugin runs a pool of engine instances, one per native thread, mirroring the desktop worker pools (`apps/cli/src/lib/worker-pool-bun.ts`, `apps/desktop/src/lib/worker-pool-electron-main.ts`).
- Each pool slot is a native thread (iOS `DispatchQueue` / `Thread`, Android a thread in an `ExecutorService`) owning its own JS engine context (JavaScriptCore on iOS, QuickJS on Android) with its own copy of `worker.bundle.js` evaluated once and its own `host` bridge installed. Engine contexts are not shared between threads (neither JSC nor QuickJS contexts are thread-safe).
- The plugin keeps a pending-task FIFO. `addTask` enqueues; a dispatcher hands the next pending task to any idle engine. When an engine finishes, it picks up the next task. This gives true parallelism up to the pool size.
- Pool size is configurable with a small default (for example 2 to 4). Each engine costs memory (its own context plus a copy of the bundle), so the default stays small and can be tuned per device. A size of 1 degrades gracefully to serial execution.
- Within a single engine, async handlers still interleave on its event loop, so an engine awaiting a host call is not blocked; the pool adds CPU parallelism on top of that.
- Cancellation is by source across the whole pool: `cancelTasks(source)` adds the source to the shared cancelled set and drops matching pending tasks; any engine currently running a task for that source observes it via `host.isCancelled(taskId)`.
- Host functions are called concurrently from multiple engine threads, so every native host function (storage IO, `sha256`, media tools, `sendMessage`) must be thread-safe. The shared structures (pending queue, running-task map, cancelled set) must be guarded by a lock.

### Concern 1: compiling and packaging the worker .ts for the engine
1. Add a mobile worker entry `packages/api` (or a new `packages/mobile-worker`) file `mobile-worker-entry.ts` that calls `initTaskHandlers()` (registers every handler) and assigns `globalThis.Worker = { runTask }`, where `runTask(taskId, type, dataJson)` parses the data, builds an `ITaskContext`, and `await`s `executeTaskHandler(type, data, context)`.
2. Bundle it with `bun build` into `worker.bundle.js`, using the repo's standard bundler (the same `bun build` used by `apps/desktop` and `apps/cli`): `bun build ./mobile-worker-entry.ts --outfile worker.bundle.js --format=iife --target=browser`. The entry assigns `globalThis.Worker` itself, so no bundler global-name is set. JavaScriptCore and QuickJS both support modern ES and real promises, so async handlers need no transpile.
3. Replace Node-only dependencies at bundle time so the bundle is self-contained and engine-runnable (the complete set is governed by the Node API inventory below). The main categories:
   - Storage: swap `openStorage` / the Node `FileStorage` for a `HostStorage` that implements `IStorage` by calling host bridge functions (`host.storageRead`, `host.storageWrite`, `host.storageList`, `host.storageDelete`, `host.storageStat`). Native implements these against the device storage backend selected in `plan-mobile-storage-options.md`. Use a `bun build` alias (a Bun build plugin or a `bunfig.toml` alias) so handler imports of the storage package resolve to the mobile implementation.
   - Remove the worker-pool layer (`worker_threads`, `child_process`): the engine itself is the worker, so the bundle contains only the handler registry and `executeTaskHandler`, not the pool.
   - `Buffer`: rely on Bun's browser-target Node polyfills (`bun build --target=browser` provides a `Buffer` polyfill) or refactor the touched code to `Uint8Array`. Bytes cross the host bridge as base64 strings.
   - `crypto` (used by hashing and `packages/merkle-tree`): provide a JS implementation in the bundle, or expose `host.sha256` and call native. Decide per hot path; hashing large files should be a native host call for speed.
   - Media tools (`magick` / `ffmpeg` / `ffprobe`, used by thumbnail/transcode/probe handlers): these cannot run in JS. Expose host functions (`host.imageResize`, `host.videoTranscode`, `host.ffprobe`) implemented natively with platform image/video frameworks. Handlers that need them call the host; pure handlers (db reads, hashing, sync logic, check/verify) need no media host calls.
4. Build `worker.bundle.js` as part of the mobile app build and copy it into both native projects (Android `assets/`, iOS app resource) before `cap sync`, exactly as the prototype copies its bundle.

### The Node/Bun API surface and the host bridge (inventory and native implementations)
The worker handlers and the packages they import (`storage`, `node-api`, `merkle-tree`, `utils`, ...) use Node/Bun runtime APIs that do not exist in a bare JS engine. Each one must be deliberately accounted for, not discovered by accident at runtime.
1. Produce a complete inventory before implementation. Bundle the worker entry with `bun build --target=browser`: Bun does not supply Node built-ins such as `fs`/`child_process` for the browser target, so they surface as build errors. Because Bun does polyfill some built-ins (for example `Buffer`, `path`), the grep is the authoritative backstop: grep the worker code and its dependency packages for `node:`, `fs`, `fs/promises`, `path`, `crypto`, `os`, `stream`, `child_process`, `worker_threads`, `Buffer`, and `process`. The result is the full list of runtime APIs to deal with. Known so far: `fs`/`fs/promises`, `path`, `crypto`, `Buffer`, `stream`, `os`, `child_process` (media tools only), `worker_threads` (pool, dropped).
2. For each API decide one of two resolutions and record it:
   - Pure-JS shim bundled into `worker.bundle.js` (for example `path`, small `Buffer`/`Uint8Array` helpers, a JS `stream` shim). No native code.
   - A native host function on the `host` bridge, implemented in both Swift (iOS) and Java (Android) (for example storage IO, `host.sha256`, the media tools). These are the "native versions of Node functions" the work has to build.
3. Maintain a host-bridge checklist in the repo (a markdown table) mapping every host function to its status per platform: `not-started` / `stubbed` / `implemented` / `tested`, for iOS and Android separately. This is the source of truth for what native work remains.

### Unimplemented host functions must fail loudly (never silently)
At any point the worker code may call a host function whose native implementation does not exist yet. That must produce an immediate, unmistakable error, never a silent `undefined`, a hang, or a wrong result.
1. Error message format, used verbatim on both platforms: `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`
2. Enforce on the native side: the host-bridge dispatch's default/unknown-method branch throws/rejects with that message, including the called function name and platform. A function that is declared but intentionally not finished throws the same message from its body (a one-line `notImplemented("name")` helper on each platform).
3. Enforce on the embedded-JS side: when the bundle builds the `host` object, any expected host method that native did not install is replaced by a stub that throws the same message. This catches the case where native simply never registered the function.
4. The error must propagate as the task's failure: `runTask` lets it reject, native catches it and sends it as the `errorMessage` in the `taskCompleted` event, so it appears in the UI and the logs. It must also be written to the native log (`NSLog` / `android.util.Log`) at error level so it is visible during native debugging.
5. The checklist `stubbed` status means exactly this: declared, throws the NOT IMPLEMENTED error, not yet real.

### Concern 2: dispatch into native, translation to embedded JS, and results/events back to the web app
The full round trip, mirroring the Electron IPC backend but over the Capacitor plugin bridge:
1. App code uses `TaskQueue` unchanged. `TaskQueue.addTask` calls `IQueueBackend.addTask`, which is `EmbeddedJsQueueBackend.addTask(type, data, source, taskId)`. It calls the plugin: `JsEngine.addTask({ taskId, type, data, source })` and fires its `onTaskAdded` callbacks.
2. The native plugin enqueues the task; the pool dispatcher (see the concurrency model) hands it to an idle engine thread, which marshals `data` to JSON and calls the embedded entry `globalThis.Worker.runTask(taskId, type, dataJson)` through that engine's runner (the prototype's `__invokeTask` JSON-string convention generalised: input and result cross as JSON strings). Multiple tasks run on different engine threads at once, up to the pool size.
3. The embedded `runTask` builds an `ITaskContext` whose `sendMessage(message)` calls `host.sendMessage(taskId, JSON.stringify(message))`, whose `isCancelled()` calls `host.isCancelled(taskId)`, and whose `uuidGenerator` / `timestampProvider` / `sessionId` come from the host or a JS implementation. It then `await`s `executeTaskHandler(type, data, context)`.
4. Streaming events: when a handler calls `context.sendMessage(...)`, native receives `host.sendMessage` and calls `notifyListeners("taskMessage", { taskId, message })`. `EmbeddedJsQueueBackend` listens via `JsEngine.addListener("taskMessage", ...)` and fires its `onTaskMessage` / `onAnyTaskMessage` callbacks, so `TaskQueue.onTaskMessage` subscribers (for example the import progress UI) update.
5. Cancellation: `EmbeddedJsQueueBackend.cancelTasks(source)` calls `JsEngine.cancelTasks({ source })`; native adds the source to its cancelled set and the running handler observes it on its next `context.isCancelled()` via `host.isCancelled`. Native also fires `onTasksCancelled` locally as the Electron backend does.
6. Completion: when the handler promise resolves, native serialises the result and calls `notifyListeners("taskCompleted", { taskId, result })` (failures, including the NOT IMPLEMENTED error, send an error result). `EmbeddedJsQueueBackend` listens via `JsEngine.addListener("taskCompleted", ...)` and fires its completion callbacks, resolving `TaskQueue.awaitTask` and `onTaskComplete` subscribers. The rest of the app (for example `packages/user-interface/src/context/asset-database-source.tsx`) is unchanged.

Threading: the engine runs on a native background thread/dispatch queue, never the WebView's main thread, which is the property a later background-execution effort (BGTaskScheduler / WorkManager) builds on.

## Steps
1. Inventory the Node/Bun API surface used by the worker code (`bun build --target=browser` surfacing unresolved Node built-ins, plus the grep list above as the authoritative backstop) and create the host-bridge checklist file mapping each API/function to a resolution (JS shim or native host function) and a per-platform status.
2. Create the mobile worker entry and bundle. Add `mobile-worker-entry.ts` that registers handlers and exposes `globalThis.Worker = { runTask }`, and a `bun build` script producing `worker.bundle.js` (config as in Concern 1). Include the JS-side host stubs that throw the NOT IMPLEMENTED error for any host method native did not install.
3. Implement `HostStorage` (mobile `IStorage` over `host.storage*`) and the esbuild alias that points the handlers' storage import at it. Add the `Buffer` / `crypto` shims or host calls per the inventory.
4. Add the native `notImplemented(name)` helper on both platforms and wire the host-bridge dispatch so every unknown or unfinished host function throws the exact NOT IMPLEMENTED message and logs it at error level.
5. Add native media host functions (`host.imageResize`, `host.videoTranscode`, `host.ffprobe`); until each is real it stays `stubbed` (throws NOT IMPLEMENTED), so pure handlers (hash/check/verify/db reads/sync) work end to end first.
6. Wire the bundle build + copy into both native projects before `cap sync` (reuse the prototype's `build:bundle` / `copy:bundle` scripts).
7. Implement the `JsEngine` Capacitor plugin JS interface (`registerPlugin`) with `addTask`, `cancelTasks`, and the `taskCompleted` / `taskMessage` listeners.
8. Implement `EmbeddedJsQueueBackend implements IQueueBackend` in the mobile frontend lib, modelled on `ElectronRendererQueueBackend`. Replace `MobileQueueBackend` and call `setQueueBackend(new EmbeddedJsQueueBackend())` in `apps/android-frontend/src/app.tsx` and `apps/ios-frontend/src/app.tsx`.
9. Implement the native engine pool and dispatcher on both platforms, modelled on the desktop worker pools and especially `apps/cli/src/lib/worker-pool-bun.ts` (its idle/ready slot tracking, FIFO dispatch, and per-worker lifecycle are the closest reference). The pool holds N engine threads (configurable, small default), a shared pending-task FIFO, a running-task map, and a cancelled-source set, all lock-guarded; the dispatcher assigns the next pending task to any idle engine and reassigns when an engine frees. This is the shared structure both platform engine hosts plug into.
10. Implement the iOS plugin and JavaScriptCore engine host (Swift), reusing the prototype `engine/ios-javascriptcore` runner: each pool thread creates a `JSContext`, evaluates `worker.bundle.js`, installs the host bridge (including the `notImplemented` guard), runs `Worker.runTask`, and emits `notifyListeners` events.
11. Implement the Android plugin and QuickJS engine host (Java, Quack binding), reusing the prototype `engine/android-quickjs` runner: each pool thread owns a QuickJS context with the same responsibilities and `notImplemented` guard. Keep Rhino as a documented sync-only fallback.
12. Implement the native storage host functions against the storage backend chosen in `plan-mobile-storage-options.md`, updating the checklist status as each lands.
13. Wire the mobile platform context to the embedded engine, replacing the current no-op stubs in `apps/android-frontend/src/lib/platform-provider-mobile.tsx` (and the iOS equivalent): `cancelTasks(source)` calls `JsEngine.cancelTasks({ source })` (the same path `EmbeddedJsQueueBackend.cancelTasks` uses), and `onTaskMessage` / `onTaskComplete` subscribe to the plugin's `taskMessage` / `taskCompleted` events. This is required for UI that drives tasks through the platform context, notably the Job Manager (`plan-job-manager.md`), whose Cancel button calls `platform.cancelTasks(sourceTag)`; without this wiring that cancel is a no-op on mobile.

## Unit Tests
- `EmbeddedJsQueueBackend` test: with a mock `JsEngine` plugin, assert `addTask` forwards the right payload and fires `onTaskAdded`, that a simulated `taskMessage` event fires `onTaskMessage` (type-filtered and any), that a simulated `taskCompleted` event fires completion callbacks, and that `cancelTasks` forwards and fires `onTasksCancelled`. Mirrors the existing `electron-renderer-queue-backend.test.ts`.
- `runTask` mobile worker entry test (under Bun): with a mock `globalThis.host`, dispatch a representative pure handler (for example `check-file` or `hash-file`) through `runTask` and assert the result and that `sendMessage` / `isCancelled` route through the host.
- `HostStorage` test: assert each `IStorage` method calls the matching `host.storage*` function and marshals bytes as base64 correctly.
- NOT IMPLEMENTED guard test (JS side): build the `host` object with one method deliberately not installed, call it through a handler, and assert the task fails with the exact `NOT IMPLEMENTED: native host function "<name>" ...` message.
- Native host-function unit tests, one per implemented host function, on both platforms:
  - iOS (XCTest): drive the JSC host bridge directly (storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, `sendMessage` capture, `isCancelled`) and assert behaviour. Include a test that an unfinished/unknown host function throws the exact NOT IMPLEMENTED message and logs it.
  - Android (JUnit / Robolectric, or instrumented where a real device API is needed): the same coverage against the QuickJS host bridge, including the NOT IMPLEMENTED case.

## Smoke Tests
- QuickJS parity test (the key automated, no-device proof): build `worker.bundle.js`, load it into QuickJS via `quickjs-emscripten` with a mock host (in-memory storage), call `globalThis.Worker.runTask(...)` for a real pure handler, and assert the result. Proves the actual handlers run under the same engine family used on Android, off-device. Extends the prototype's parity test from the toy task to real handlers. Add a parity case that calls a deliberately unimplemented host function and asserts the NOT IMPLEMENTED failure.
- Build-and-wire smoke: build the bundle and assert it lands at the Android assets path and the iOS app resource path.
- Native build checks for both platforms with the new plugin, runner, and host functions.
- JavaScriptCore parity test (the iOS-engine off-device proof, macOS only): run the same built `worker.bundle.js` through JavaScriptCore using the system `jsc` binary (or a tiny Swift XCTest harness that loads the bundle into a `JSContext`) with a mock host, call `globalThis.Worker.runTask(...)` for a real pure handler, and assert the same result as the QuickJS case. Covers the iOS engine, not just the Android (QuickJS) engine. Where `jsc`/macOS is unavailable in CI, this runs in the iOS XCTest suite on the simulator instead.
- Automated on-device background-task smoke test (the key proof that tasks actually run in the engine on a device): using the mobile smoke harness from `plan-mobile-smoke-tests.md` (host control bridge + WebSocket into the app), dispatch a real background task from the web app on a booted Android emulator and iOS simulator, then assert: the task completes with the expected result, the streamed `taskMessage` progress events arrive in order, and `cancelTasks` cancels a running task. Add this as `test.sh` cases under the mobile smoke-tests `tests/` directory (for example `tests/N-background-task-hash/test.sh`), driven entirely from the host so it is automated, not a manual UI run. Gated on the storage host functions existing (it needs `HostStorage`-backed read/write).
- On-device host-function smoke: as part of the above, exercise the real native host functions (storage read/write, hashing) end to end on each platform and confirm the result and streamed messages.
- Parallelism smoke test: with a pool size of at least 2, dispatch two long-running tasks (for example a load-assets and an import-assets, or two hashes) and assert from their interleaved/streamed messages and timing that both run concurrently rather than strictly one-after-another. Add a pool-size-1 variant that asserts serial execution, confirming the dispatcher honours the configured size.

## Verify
- Run all unit tests (TS and native) and confirm they pass, including the NOT IMPLEMENTED guard tests.
- Run the QuickJS and JavaScriptCore parity smoke tests against `worker.bundle.js` and confirm a real handler returns the expected result under both engines, and that the unimplemented-host-function case fails with the exact NOT IMPLEMENTED message.
- Build the Android project (QuickJS/Quack dependency + plugin) and the iOS project (JavaScriptCore plugin) and confirm both compile.
- Run the automated on-device background-task smoke test on a booted Android emulator and iOS simulator and confirm a real task dispatched from the web app completes with the expected result, streams its progress messages, and cancels on request, proving the handler ran in the native-embedded engine and results reached the web app. This replaces any manual "run it from the UI" check.
- Confirm the host-bridge checklist is current: every host function used by a shipped handler is `implemented` and `tested` on both platforms, and any remaining `stubbed` function throws the NOT IMPLEMENTED error rather than failing silently.
- Run the full repo `bun run test:all` to confirm desktop/CLI task paths are unaffected.

## Notes
- This commits the embedded-JS-engine option from the earlier options analysis; the other options (server offload, Web Workers + WASM, full native rewrite) are no longer the plan.
- Tied to `plan-mobile-storage-options.md`: the host storage functions are backed by the native storage backend chosen there. The embedded worker reaches storage only through that bridge.
- Native versions of Node functions are a first-class deliverable, tracked by the host-bridge checklist. The checklist plus the NOT IMPLEMENTED rule mean an unimplemented function is always visible (loud error, failed task, error log) and never silently skipped.
- Media handlers (thumbnail, transcode, probe) need native host implementations because `magick` / `ffmpeg` / `ffprobe` cannot run in the JS engine. Sequence the work so pure handlers land first and media handlers follow once the native tool host functions exist; until then those host functions stay `stubbed` and throw NOT IMPLEMENTED.
- Rhino (Android) and Duktape (iOS) remain documented fallbacks from the prototype, but both are ES5/sync-era and would require transpiling the bundle and reducing it to synchronous handlers, so they are not the target. JavaScriptCore and QuickJS are the supported engines because they run the async handlers as-is.
- Running tasks while the app is suspended (BGTaskScheduler / WorkManager) is deliberately out of scope here. Because the engine already runs off the WebView on a native thread, that is a later, separable addition.
- Reference implementations to copy from: the prototype's `engine/ios-javascriptcore` and `engine/android-quickjs` runners and `JsEngine` plugin; `apps/desktop-frontend/src/lib/electron-renderer-queue-backend.ts` for the queue-backend-over-a-bridge pattern; and `apps/cli/src/lib/worker-pool-bun.ts` (with `apps/desktop/src/lib/worker-pool-electron-main.ts`) for the pool dispatcher, idle/ready slot tracking, and per-engine lifecycle.
- Thread-safety: because the pool calls into native host functions from multiple engine threads at once, every host function (storage IO, `sha256`, media tools, `sendMessage`, `isCancelled`) must be thread-safe, and the shared pending queue / running-task map / cancelled-source set must be lock-guarded. JS engine contexts are per-thread and never shared. This is the main new hazard the pool introduces over a single engine.
</content>
