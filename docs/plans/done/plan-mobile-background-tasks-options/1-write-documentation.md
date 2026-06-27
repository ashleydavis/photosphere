# Step 1: Write documentation

Draft the documentation for the mobile background-tasks feature as it is intended to work, so the design can be read and understood before any code is written. This is forward-looking documentation describing the target behaviour; it will be revised at the end (final step) to match what actually shipped.

## What to write

Update `docs/background-tasks.md` (or add a clearly marked "Mobile (embedded JS engine)" section) describing the intended mobile path:

- How a background task runs on mobile: the TypeScript orchestration (`packages/task-queue`) is reused; handlers (`packages/node-api/src/lib/*.worker.ts`) are compiled into a single `worker.bundle.js` and executed by an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android), driven from native code off the WebView.
- The round trip: `TaskQueue.addTask` -> `EmbeddedJsQueueBackend` -> native `JsEngine` Capacitor plugin (pending FIFO + pool dispatcher) -> embedded engine `globalThis.__photosphereWorker.runTask` -> `executeTaskHandler` -> results/messages back via `notifyListeners` (`taskCompleted` / `taskMessage`).
- The host bridge: define it (the `globalThis.host` object of native functions the engine calls, the only way out of the sandboxed engine). Explain that handlers may use whatever Node APIs they need; the build redirects each Node built-in to a small module that does the work in TypeScript where possible, or calls a native `host.*` function where it needs the device. Storage is bridged at the Node `fs` boundary so `FileStorage` and `node-utils` run unchanged.
- The NOT IMPLEMENTED rule: any unimplemented host function fails loudly with the exact message `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`, surfaced as the task's error result and logged at error level.
- The concurrency model (pool of engine threads, `POOL_SIZE` build constant, default 3), cancellation by source, and thread-safety expectations for host functions.
- Security notes: path sandboxing to the storage root (reject `..`/absolute paths), and that `worker.bundle.js` is only ever eval'd from the packaged app asset, never a remote/OTA source.

Keep it consistent with the existing structure and tone of `docs/background-tasks.md`. Keep it high level: describe the design, not an enumerated list of every host function (which dates quickly), and do not link out to the plan files or reference a separate checklist document.

## How to check on Android

Not applicable: this step only writes documentation. Verify by reading the mobile section of `docs/background-tasks.md`.

## Summary

Added a new "Mobile (embedded JS engine)" section to `docs/background-tasks.md`, after the top-level "How it works" overview (with a one-line pointer added to that overview noting mobile has no Node runtime). The section is forward-looking and covers:

- How a task runs on mobile: `packages/task-queue` reused; handlers compiled into `worker.bundle.js` run by JavaScriptCore (iOS) / QuickJS (Android), with the `globalThis.__photosphereWorker` exposure detail.
- The full round trip, including the fire-and-forget local-id and dispatch-rejection handling.
- The host bridge: defined as `globalThis.host`. Handlers may use whatever Node APIs they need; the build redirects each Node built-in to a module that does the work in TypeScript where possible or calls a native `host.*` function where the device is needed. Storage is bridged at the Node `fs` boundary (not `IStorage`) so `FileStorage` and `node-utils` run unchanged on a native-backed `fs`.
- The NOT IMPLEMENTED rule and exact message.
- Concurrency model (`POOL_SIZE`, FIFO + idle-slot dispatch, size-1 serial), cancellation by source, thread-safety.
- Security notes: path sandbox; packaged-asset-only bundle.

Notes / divergences:
- Corrected the handler path to `packages/node-api/src/lib/`; the older tutorial portion of the doc still says `packages/api`, left unchanged to keep this step's edit minimal.
- Storage uses the native-backed `fs` seam (`host.fs*`), superseding the earlier `HostStorage`-over-`host.storage*` sketch.
- Kept the doc high level and free of plan-file links or a separate host-bridge checklist document, per review feedback. The host-function inventory and per-platform status live in the plans, not the docs.
- Docs-only change: compile and tests are unaffected.
