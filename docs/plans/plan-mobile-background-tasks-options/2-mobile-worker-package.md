# Step 2: Create the shared `packages/mobile-worker` package

Create the shared workspace package that holds the embedded worker entry, the bundle build, and the JS-side host stubs.

## What to do

1. Add `packages/mobile-worker` as a `workspace:*` package with its own `package.json`, `tsconfig`, and `src/test` directory.
2. Add `mobile-worker-entry.ts` that:
   - calls `initTaskHandlers()` to register every handler, and
   - assigns `globalThis.__photosphereWorker = { runTask }`, where `runTask(taskId, type, dataJson)` parses `dataJson`, builds an `ITaskContext`, and `await`s `executeTaskHandler(type, data, context)`.
   - The global is named `__photosphereWorker` (never `Worker`) so it cannot shadow the Web Worker constructor or collide in the parity harnesses.
3. Add a `bun build` script producing `worker.bundle.js`:
   - `bun build ./mobile-worker-entry.ts --outfile worker.bundle.js --format=iife --target=browser`.
   - The entry assigns the global itself; do not set a bundler global-name (`--global-name`), so the manual assignment is the single exposure mechanism.
4. Build the `host` object so that any expected host method native did not install is replaced by a JS stub that throws the exact NOT IMPLEMENTED message: `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`

## Tests

- `runTask` mobile worker entry test (under Bun): with a mock `globalThis.host`, dispatch a representative pure handler (for example `check-file` or `hash-file`) through `runTask` and assert the result, that `sendMessage` / `isCancelled` route through the host, and that `sessionId` from the host reaches the context.
- NOT IMPLEMENTED guard test (JS side): build the `host` object with one method deliberately not installed, call it through a handler, and assert the task fails with the exact `NOT IMPLEMENTED: native host function "<name>" ...` message.

Run all tests and confirm they pass before marking this step complete.

## How to check on Android

Off-device, no emulator. Build the bundle, then load it into QuickJS (the same engine family Android uses) via `quickjs-emscripten` with a mock `host` and call `globalThis.__photosphereWorker.runTask(...)`. If a real handler returns its result under QuickJS, the bundle runs on the Android engine. Run it through `bun run test`. Also confirm the build script actually emits `worker.bundle.js`.

## Summary

Created the shared `packages/mobile-worker` workspace package that holds the embedded worker entry, the host-bridge stub machinery, and the bundle build script.

Files added:
- `packages/mobile-worker/package.json` — `workspace:*` package depending on `node-api`, `task-queue`, `utils`. Scripts mirror the other leaf packages (`compile`, `test`, `clean`) plus `build:bundle` (`bun build ./mobile-worker-entry.ts --outfile worker.bundle.js --format=iife --target=browser`, no `--global-name`).
- `packages/mobile-worker/tsconfig.json` — mirrors the standard leaf tsconfig; `rootDir` is `.` and the include list covers both the root entry and `src/**/*`.
- `packages/mobile-worker/jest.config.js` — `ts-jest`, node env, and a `moduleNameMapper` reusing the existing `packages/task-queue/__mocks__/serialize-error.js` mock (the same approach `desktop-frontend`/`dev-frontend` use) so the ESM-only `serialize-error` transitive import does not break jest.
- `packages/mobile-worker/src/lib/host.ts` — `IHost` interface, `HostPlatform`, `EXPECTED_HOST_FUNCTIONS` (the single extension point: `sendMessage`, `isCancelled`, `sha256` for this slice), `notImplementedMessage(name, platform)`, and `buildHost(rawHost)`, which returns the effective host where any expected function native did not install is replaced by a stub that throws the exact `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.` message.
- `packages/mobile-worker/src/lib/mobile-worker-runtime.ts` — `runTask(taskId, type, dataJson)` which wraps `globalThis.host` via `buildHost` (writing it back so the storage shims added in step 3 also see the stubs), builds an `ITaskContext` (uuid via `RandomUuidGenerator`, timestamp via `TimestampProvider`, `sessionId` from the host, `sendMessage`/`isCancelled` routed through the host), and `await`s `executeTaskHandler`. Input and result cross as JSON strings. `installWorkerGlobal()` assigns `globalThis.__photosphereWorker = { runTask }` (named `__photosphereWorker`, never `Worker`).
- `packages/mobile-worker/src/index.ts` — re-exports the host and runtime modules.
- `packages/mobile-worker/mobile-worker-entry.ts` — the bundle entry: calls `initTaskHandlers()` then `installWorkerGlobal()`.

Tests (`src/test`, 6 passing under Bun/jest):
- `mobile-worker-runtime.test.ts` — runTask routes `sendMessage`/`isCancelled` through a mock host and `sessionId` reaches the context; runTask rejects when `globalThis.host` is missing; `installWorkerGlobal` exposes a working `runTask`.
- `host.test.ts` — `buildHost` stubs a missing function (exact NOT IMPLEMENTED message), keeps installed native functions, and a handler calling an unimplemented host function fails the task with the exact message.

Decisions / divergences:
- The runtime (`runTask`, `buildHost`) lives in `src/lib` and is independent of `node-api`; only the entry imports `node-api`. This keeps the unit tests light and fast and isolates the bundle-only dependency in the entry.
- The runTask unit test uses a registered representative handler rather than the real `check-file`/`hash-file` handlers. Those handlers require full storage/database/`fs` fixtures and, more importantly, the Node-builtin shims that land in step 3; running a real handler end-to-end under an engine is the QuickJS/JSC parity smoke test, which becomes runnable after step 3.
- The task context is built as a plain `ITaskContext` object (not the `TaskContext` class) because mobile `isCancelled` must route to `host.isCancelled(taskId)` rather than the class's internal cancel flag.

Deferred to step 3 (as planned): `bun run build:bundle` currently fails because the browser target surfaces unshimmed Node builtins (`stream/promises`, `child_process`, etc.) pulled in transitively by `node-api`. This is exactly the inventory step 3 ("Wire the Node-builtin shims and bundle aliases") resolves. The build script is wired and surfaces the inventory; the bundle does not yet emit, so the off-device QuickJS parity check in "How to check on Android" is not runnable until step 3 (plus the `fs` shims from `plan-mobile-storage-options.md`).
