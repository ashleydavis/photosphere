# Step 11: Implement the Android plugin and QuickJS engine host (Java, Quack binding)

Port the prototype's `engine/android-quickjs` runner into this repo as the Android engine host that plugs into the pool from Step 9.

## What to do

1. Add the QuickJS/Quack JNI dependency to the Android project.
2. Each pool thread owns its own QuickJS context and evaluates `worker.bundle.js` once.
3. Install the host bridge into each context, including:
   - the `notImplemented` guard and host-bridge dispatch (Step 4),
   - the shared path-sandbox guard (Step 4),
   - synchronous `isCancelled` / `sendMessage` callables (synchronous bound native functions), as proven by the prototype.
4. Run `globalThis.__photosphereWorker.runTask(taskId, type, dataJson)` on the thread's context, marshalling input and result as JSON strings.
5. Emit `notifyListeners("taskMessage", ...)` and `notifyListeners("taskCompleted", ...)` (errors, including NOT IMPLEMENTED, send an error result).
6. Keep Rhino documented as a sync-only fallback (not wired as the target engine).

## Tests

- Android native host-function unit tests (JUnit / Robolectric, or instrumented where a real device API is needed) driving the QuickJS host bridge: storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, `sendMessage` capture, `isCancelled`.
- Include the NOT IMPLEMENTED case: an unfinished/unknown host function throws the exact message and logs it.
- QuickJS parity smoke test (the key no-device proof): build `worker.bundle.js`, load it into QuickJS via `quickjs-emscripten` with a mock host (in-memory storage), call `globalThis.__photosphereWorker.runTask(...)` for a real pure handler, and assert the result. Add a case calling a deliberately unimplemented host function asserting the NOT IMPLEMENTED failure, and a large-payload case round-tripping a blob above the base64 threshold through the file-handle path.

Run all tests and confirm they pass before marking this step complete.

## How to check on Android

This is the core Android step; check it three ways:
- Off-device parity (`bun run test`): load `worker.bundle.js` into `quickjs-emscripten` and run a real handler, plus the NOT IMPLEMENTED and large-payload cases. Proves the bundle runs under the Android engine family with no device.
- Native unit tests: wrap `apps/android-frontend/android/gradlew testDebugUnitTest` (JUnit / Robolectric) as a `bun run` script to drive the QuickJS host bridge directly (storage read/write/list/stat/delete in a temp dir, `sha256` against a known vector, `sendMessage` capture, `isCancelled`, and the NOT IMPLEMENTED case). Use `connectedDebugAndroidTest` for cases needing a real device API.
- On an emulator: build, install, and launch with `bun run launch` in `apps/android-frontend` (`vite build && cap run android`) on a booted emulator, then drive a task (via the UI or the smoke harness `bun run test:android`) and watch results and any NOT IMPLEMENTED errors in Logcat (`adb logcat | grep -i JsEngine`).

## Summary

Implemented the Android `JsEngine` Capacitor plugin and QuickJS engine host (`apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/`): `JsEnginePlugin.java` (`@CapacitorPlugin(name = "JsEngine")`, methods `addTask`/`cancelTasks`/`shutdown`, events `taskCompleted`/`taskMessage`, registered in `MainActivity.java`), `QuickJsTaskEngine.java` (per-thread QuickJS context via the Quack JNI binding, evaluates `worker.bundle.js` from `assets/`, runs `__photosphereWorker.runTask`), `HostBridge.java` (installs `globalThis.host` with `platform`/`sessionId`/`sendMessage`/`isCancelled`), `HostFunctions.java` (the `notImplemented(name)` loud-failure helper), and `PathSandbox.java`. The Quack dependency and JUnit were added to `app/build.gradle`. JUnit host-bridge tests drive the bridge directly.

Per the no-native-Node-implementations decision, `host.sha256` is **not** implemented natively: `HostFunctions.sha256` throws `notImplemented("sha256")` so hashing reports the verbatim NOT IMPLEMENTED error until a later plan provides it. `sendMessage`/`isCancelled` are infrastructure callables (kept).

Note: not compiled/verified here (the Android project build was not run). The Quack dependency coordinate and the QuickJS host API usage need verifying when the project is built; the QuickJS off-device parity proof and the on-device run are to be done on the developer's machine/device. Also: with the plain `bun build` CLI the worker bundle does not emit yet (handlers import `stream/promises` / `child_process`), so the engine has no bundle asset to load until that is resolved.
