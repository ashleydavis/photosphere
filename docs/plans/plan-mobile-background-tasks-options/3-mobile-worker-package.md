# Step 3: Create the shared `packages/mobile-worker` package

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

## Summary

_To be completed when this step is implemented._
