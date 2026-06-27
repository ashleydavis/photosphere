# Step 11: Implement the iOS plugin and JavaScriptCore engine host (Swift)

Port the prototype's `engine/ios-javascriptcore` runner into this repo as the iOS engine host that plugs into the pool from Step 10.

## What to do

1. Each pool thread creates its own `JSContext` and evaluates `worker.bundle.js` once.
2. Install the host bridge into each context, including:
   - the `notImplemented` guard and host-bridge dispatch (Step 5),
   - the shared path-sandbox guard (Step 5),
   - synchronous `isCancelled` / `sendMessage` callables (via `JSObjectMakeFunctionWithCallback`), proven by the prototype's synchronous host callables.
3. Run `globalThis.__photosphereWorker.runTask(taskId, type, dataJson)` on the thread's context, marshalling input and result as JSON strings (the prototype's `__invokeTask` convention generalised).
4. Emit `notifyListeners("taskMessage", ...)` and `notifyListeners("taskCompleted", ...)` (errors, including NOT IMPLEMENTED, send an error result).
5. The plugin is torn down on app teardown so engine threads never outlive the plugin.

## Tests

- iOS native host-function unit tests (XCTest) driving the JSC host bridge directly: storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, `sendMessage` capture, `isCancelled`.
- Include the NOT IMPLEMENTED case: an unfinished/unknown host function throws the exact message and logs it.
- JavaScriptCore parity test (macOS): run the built `worker.bundle.js` through JavaScriptCore (system `jsc` or a tiny Swift XCTest harness loading the bundle into a `JSContext`) with a mock host, call `runTask` for a real pure handler, and assert the result matches the QuickJS case. Where `jsc`/macOS is unavailable in CI, run it in the iOS XCTest suite on the simulator instead.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
