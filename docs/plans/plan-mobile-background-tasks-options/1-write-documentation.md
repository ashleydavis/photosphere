# Step 1: Write documentation

Draft the documentation for the mobile background-tasks feature as it is intended to work, so the design can be read and understood before any code is written. This is forward-looking documentation describing the target behaviour; it will be revised at the end (final step) to match what actually shipped.

## What to write

Update `docs/background-tasks.md` (or add a clearly marked "Mobile (embedded JS engine)" section) describing the intended mobile path:

- How a background task runs on mobile: the TypeScript orchestration (`packages/task-queue`) is reused; handlers (`packages/node-api/src/lib/*.worker.ts`) are compiled into a single `worker.bundle.js` and executed by an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android), driven from native code off the WebView.
- The round trip: `TaskQueue.addTask` -> `EmbeddedJsQueueBackend` -> native `JsEngine` Capacitor plugin (pending FIFO + pool dispatcher) -> embedded engine `globalThis.__photosphereWorker.runTask` -> `executeTaskHandler` -> results/messages back via `notifyListeners` (`taskCompleted` / `taskMessage`).
- The host bridge: what native host functions exist (storage IO, `sha256`, media tools, `sendMessage`, `isCancelled`), and the rule that a new task type must not do direct Node IO and must route through the host bridge.
- The host-bridge checklist (`docs/mobile-host-bridge-checklist.md`) and what its statuses mean (`not-started` / `stubbed` / `implemented` / `tested`, per platform).
- The NOT IMPLEMENTED rule: any unimplemented host function fails loudly with the exact message `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`, surfaced as the task's error result and logged at error level.
- The concurrency model (pool of engine threads, `POOL_SIZE` build constant, default 3), cancellation by source, and thread-safety expectations for host functions.
- Security notes: path sandboxing to the storage root (reject `..`/absolute paths), and that `worker.bundle.js` is only ever eval'd from the packaged app asset, never a remote/OTA source.

Keep it consistent with the existing structure and tone of `docs/background-tasks.md`.

## Summary

_To be completed when this step is implemented._
