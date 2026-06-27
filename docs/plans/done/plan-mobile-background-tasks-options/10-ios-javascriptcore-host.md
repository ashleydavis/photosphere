# Step 10: Implement the iOS plugin and JavaScriptCore engine host (Swift)

Port the prototype's `engine/ios-javascriptcore` runner into this repo as the iOS engine host that plugs into the pool from Step 9.

## What to do

1. Each pool thread creates its own `JSContext` and evaluates `worker.bundle.js` once.
2. Install the host bridge into each context, including:
   - the `notImplemented` guard and host-bridge dispatch (Step 4),
   - the shared path-sandbox guard (Step 4),
   - synchronous `isCancelled` / `sendMessage` callables (via `JSObjectMakeFunctionWithCallback`), proven by the prototype's synchronous host callables.
3. Run `globalThis.__photosphereWorker.runTask(taskId, type, dataJson)` on the thread's context, marshalling input and result as JSON strings (the prototype's `__invokeTask` convention generalised).
4. Emit `notifyListeners("taskMessage", ...)` and `notifyListeners("taskCompleted", ...)` (errors, including NOT IMPLEMENTED, send an error result).
5. The plugin is torn down on app teardown so engine threads never outlive the plugin.

## Tests

- iOS native host-function unit tests (XCTest) driving the JSC host bridge directly: storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, `sendMessage` capture, `isCancelled`.
- Include the NOT IMPLEMENTED case: an unfinished/unknown host function throws the exact message and logs it.
- JavaScriptCore parity test (macOS): run the built `worker.bundle.js` through JavaScriptCore (system `jsc` or a tiny Swift XCTest harness loading the bundle into a `JSContext`) with a mock host, call `runTask` for a real pure handler, and assert the result matches the QuickJS case. Where `jsc`/macOS is unavailable in CI, run it in the iOS XCTest suite on the simulator instead.

Run all tests and confirm they pass before marking this step complete.

## How to check on Android

Not an Android step: this is the iOS / JavaScriptCore host, verified with XCTest and the JavaScriptCore parity test on macOS. The Android equivalent is Step 11 (the QuickJS host).

## Summary

Implemented the iOS `JsEngine` Capacitor plugin and JavaScriptCore engine host (`apps/ios-frontend/ios/App/App/JsEngine/`): `JsEnginePlugin.swift` + `JsEnginePlugin.m` (bridging macro, plugin name `JsEngine`, methods `addTask`/`cancelTasks`/`shutdown`, events `taskCompleted`/`taskMessage`), `JavaScriptCoreTaskEngine.swift` (per-thread `JSContext`, evaluates `worker.bundle.js`, runs `__photosphereWorker.runTask`), `HostBridge.swift` (installs `globalThis.host` with `platform`/`sessionId`/`sendMessage`/`isCancelled`, the synchronous callables), and `PathSandbox.swift` (rejects absolute / `..` paths, confined to the storage root). XCTest files under `AppTests/` cover the host bridge, path sandbox, NOT IMPLEMENTED, dispatcher, and a JavaScriptCore bundle-parity test.

Per the no-native-Node-implementations decision, `host.sha256` is **not** implemented natively: it reports the verbatim NOT IMPLEMENTED error (`HostBridge.sha256` throws `notImplemented("sha256")`; `HostBridgeTests` asserts the exact message). `sendMessage`/`isCancelled` are infrastructure callables (kept). The `notImplemented(name)` helper is the loud-failure path for every host function a later plan has not yet implemented.

Note: not compiled/verified here (no macOS). To be built and the XCTest suite run on the developer's Mac. The XCTest files may need adding to the Xcode test target, and `JsEnginePlugin.m` to the app target.
