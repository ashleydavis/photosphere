# Step 9: Implement `EmbeddedJsQueueBackend` and wire it into both apps

Implement the queue backend that bridges the synchronous `IQueueBackend` to the async Capacitor plugin, and replace the no-op `MobileQueueBackend` in both apps.

## What to do

1. Implement `EmbeddedJsQueueBackend implements IQueueBackend` in `packages/mobile-frontend`, modelled on `apps/desktop-frontend/src/lib/electron-renderer-queue-backend.ts`:
   - `async init()` calls `JsEngine.addListener("taskCompleted", ...)` and `JsEngine.addListener("taskMessage", ...)`, awaits both `PluginListenerHandle`s, and stores them.
   - `addTask` is synchronous fire-and-forget: generate/use the taskId locally (`taskId ?? crypto.randomUUID()`), return it synchronously, invoke `JsEngine.addTask(...)` without awaiting, attach a `.catch` that synthesises a local `taskCompleted` error event for that taskId on bridge rejection, and fire `onTaskAdded` synchronously.
   - turn `taskMessage` / `taskCompleted` events into `onTaskMessage` / `onAnyTaskMessage` and completion callbacks.
   - `cancelTasks(source)` calls `JsEngine.cancelTasks({ source })` and fires `onTasksCancelled` locally.
   - `shutdown()` calls `handle.remove()` on every stored handle and then `JsEngine.shutdown()`.
2. Replace the byte-identical `MobileQueueBackend` (`apps/android-frontend/src/lib/mobile-queue-backend.ts` and `apps/ios-frontend/src/lib/mobile-queue-backend.ts`) with thin imports from `packages/mobile-frontend`.
3. In both `apps/android-frontend/src/app.tsx` and `apps/ios-frontend/src/app.tsx`, `await backend.init()` then `setQueueBackend(backend)` before any UI that dispatches tasks mounts.

## Tests

- `EmbeddedJsQueueBackend` test (mirrors `electron-renderer-queue-backend.test.ts`): with a mock `JsEngine` plugin, assert `addTask` returns the id synchronously and forwards the right payload and fires `onTaskAdded`; a simulated `taskMessage` fires `onTaskMessage` (type-filtered and any); a simulated `taskCompleted` fires completion callbacks; `cancelTasks` forwards and fires `onTasksCancelled`.
- Fire-and-forget / dispatch-rejection test: assert `addTask` does not await the plugin call (returns before the mock's Promise resolves), and that when the mocked `JsEngine.addTask` Promise rejects the backend emits a synthetic `taskCompleted` error result so `awaitTask` rejects rather than hanging.
- Listener race/cleanup test: assert `init()` awaits both `addListener` handles before resolving; simulate a `taskCompleted` event arriving before `init()` completes and assert it is still delivered (native buffer/flush mocked); assert `shutdown()` calls `handle.remove()` on every handle and `JsEngine.shutdown()`.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
