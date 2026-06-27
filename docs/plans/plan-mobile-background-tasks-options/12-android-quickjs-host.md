# Step 12: Implement the Android plugin and QuickJS engine host (Java, Quack binding)

Port the prototype's `engine/android-quickjs` runner into this repo as the Android engine host that plugs into the pool from Step 10.

## What to do

1. Add the QuickJS/Quack JNI dependency to the Android project.
2. Each pool thread owns its own QuickJS context and evaluates `worker.bundle.js` once.
3. Install the host bridge into each context, including:
   - the `notImplemented` guard and host-bridge dispatch (Step 5),
   - the shared path-sandbox guard (Step 5),
   - synchronous `isCancelled` / `sendMessage` callables (synchronous bound native functions), as proven by the prototype.
4. Run `globalThis.__photosphereWorker.runTask(taskId, type, dataJson)` on the thread's context, marshalling input and result as JSON strings.
5. Emit `notifyListeners("taskMessage", ...)` and `notifyListeners("taskCompleted", ...)` (errors, including NOT IMPLEMENTED, send an error result).
6. Keep Rhino documented as a sync-only fallback (not wired as the target engine).

## Tests

- Android native host-function unit tests (JUnit / Robolectric, or instrumented where a real device API is needed) driving the QuickJS host bridge: storage read/write/list/stat/delete against a temp directory, `sha256` against a known vector, `sendMessage` capture, `isCancelled`.
- Include the NOT IMPLEMENTED case: an unfinished/unknown host function throws the exact message and logs it.
- QuickJS parity smoke test (the key no-device proof): build `worker.bundle.js`, load it into QuickJS via `quickjs-emscripten` with a mock host (in-memory storage), call `globalThis.__photosphereWorker.runTask(...)` for a real pure handler, and assert the result. Add a case calling a deliberately unimplemented host function asserting the NOT IMPLEMENTED failure, and a large-payload case round-tripping a blob above the base64 threshold through the file-handle path.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
