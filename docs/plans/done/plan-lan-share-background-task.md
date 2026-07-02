# Refactor LAN database sharing into a background task

## Overview
LAN database sharing (the "Share database" / "Receive database" feature) currently runs only in the Electron main process: `apps/desktop/src/main.ts` holds `LanShareSender`/`LanShareReceiver` instances behind six IPC handlers, and the mobile platform provider stubs every share method as a no-op, so sharing does not work on mobile at all. This plan moves the sharing logic out of the Electron main process and into background-task handlers registered in `node-api`, then rewires both platform providers to dispatch those tasks through the shared `TaskQueue`. On desktop the tasks run in the Electron utility worker (full Node, so the feature keeps working); on mobile the same tasks dispatch to the embedded JS engine, where they fail loudly at runtime (the handler is not in the mobile `worker.bundle.js` and the Node networking APIs are not implemented) until a later native layer supplies UDP/HTTPS/TLS host functions. No native host-bridge work is in scope: the deliberate outcome on mobile is a clear task failure, not a working transfer. The win is a single shared code path for both platforms and the removal of platform-specific sharing logic from Electron main.

## Issues
<!-- Populated later by plan:check -->

## Steps

1. **Add task DTO types to `api`.** Edit `packages/api/src/lan-share/index.ts` (already re-exported from the `api` package index, so no index change is needed). Append six new exported interfaces, each with a `//` comment block on the interface and a `//` comment on every field:
   - `IReceiveShareTaskData` — field `code: string` (the pairing code the receiver advertises).
   - `IReceiveShareTaskResult` — field `payload: IDatabaseSharePayload | ISecretSharePayload | null` (payload delivered by a sender, or `null` on timeout).
   - `IShareReceiverEndpoint` — fields `address: string`, `port: number`, `certFingerprint: string` (structurally identical to `lan-share`'s `IReceiverEndpoint`; defined here so neither `api` nor `user-interface` has to depend on `lan-share`).
   - `IFindReceiverTaskData` — field `code: string` (pairing code for this share session).
   - `IFindReceiverTaskResult` — field `endpoint: IShareReceiverEndpoint | null` (discovered endpoint, or `null` on timeout).
   - `ISendPayloadTaskData` — fields `payload: IDatabaseSharePayload | ISecretSharePayload`, `code: string`, `endpoint: IShareReceiverEndpoint`.
   - `ISendPayloadTaskResult` — field `success: boolean` (true if the receiver accepted the payload).
   - Requirement: `bun run compile` type-checks cleanly for the `api` package.

2. **Add `lan-share` as a dependency of `node-api`.** Edit `packages/node-api/package.json` and add `"lan-share": "workspace:*"` to `dependencies`. Run `bun install` from the repo root so the workspace link resolves. Requirement: `node-api` can `import` from `lan-share`.

3. **Create the worker handler file.** Create `packages/node-api/src/lib/lan-share.worker.ts` with a `//` comment block above every global symbol. Contents:
   - Module constants: `SHARE_TIMEOUT_MS = 60000` and `CANCEL_POLL_INTERVAL_MS` (e.g. `250`).
   - Helper `watchForCancellation(context: ITaskContext, onCancel: () => void): () => void` — starts a `setInterval` that calls `onCancel()` when `context.isCancelled()` returns true; returns a stop function that clears the interval.
   - `receiveShareHandler(data: IReceiveShareTaskData, context: ITaskContext): Promise<IReceiveShareTaskResult>` — construct `new LanShareReceiver(SHARE_TIMEOUT_MS)`, `await receiver.start(data.code)`, start cancellation watching with `() => receiver.cancel()`, `await receiver.receive()`, stop watching in a `finally`, return `{ payload }` (cast the opaque `receive()` result to the payload union or `null`).
   - `findReceiverHandler(data: IFindReceiverTaskData, context: ITaskContext): Promise<IFindReceiverTaskResult>` — construct `new LanShareSender(undefined, data.code)`, start cancellation watching with `() => sender.cancel()`, `await sender.waitForReceiver(SHARE_TIMEOUT_MS)`, stop watching in a `finally`, return `{ endpoint }` (relies on structural compatibility between `lan-share`'s `IReceiverEndpoint` and `IShareReceiverEndpoint`).
   - `sendPayloadHandler(data: ISendPayloadTaskData): Promise<ISendPayloadTaskResult>` — construct `new LanShareSender(data.payload, data.code)`, `await sender.send(data.endpoint)`, return `{ success }`.
   - Import handler/DTO types from `api`, the classes from `lan-share`, and `ITaskContext` from `task-queue`.
   - Requirement: file type-checks cleanly and each handler has unit tests (see Unit Tests).

4. **Register the handlers.** Edit `packages/node-api/src/lib/task-handlers.ts`: import `receiveShareHandler`, `findReceiverHandler`, `sendPayloadHandler` from `./lan-share.worker`, and inside `initTaskHandlers()` add `registerHandler("receive-share", receiveShareHandler)`, `registerHandler("find-receiver", findReceiverHandler)`, `registerHandler("send-payload", sendPayloadHandler)`. Requirement: the three type strings are unique; desktop worker (`apps/desktop/src/worker.ts`) picks them up via `initTaskHandlers()`.

5. **Add `task-queue` as a dependency of `user-interface`.** Edit `packages/user-interface/package.json` and add `"task-queue": "workspace:*"` to `dependencies` (it already depends on `api` and `utils`). Run `bun install`. Requirement: `user-interface` can `import { TaskQueue, TaskStatus } from "task-queue"`.

6. **Create the shared share-task hook.** Create `packages/user-interface/src/lib/use-lan-share-tasks.ts` exporting:
   - An interface `ILanShareTasks` declaring the six methods with the exact signatures already in `IPlatformContext` (`startShareReceive(code: string): Promise<void>`, `waitShareReceive(): Promise<unknown>`, `cancelShareReceive(): Promise<void>`, `waitForReceiver(payload: unknown, code: string): Promise<unknown>`, `sendToReceiver(endpoint: unknown): Promise<boolean>`, `cancelShareSend(): Promise<void>`). Keep the `unknown` payload/endpoint types to match the existing platform interface exactly.
   - A hook `useLanShareTasks(): ILanShareTasks` that:
     - Holds a lazily-created `TaskQueue` (source constant `"lan-share"`) in a `useRef`, a `useRef` for the pending receive promise, and a `useRef` for the captured send `{ payload, code }`.
     - `startShareReceive` submits a `"receive-share"` task and stores `queue.awaitTask(taskId)` in the pending-receive ref (does not await).
     - `waitShareReceive` awaits the stored pending-receive promise; on `TaskStatus.Succeeded` returns `outputs.payload`; on `TaskStatus.Failed` throws `result.errorMessage`; otherwise returns `null` (matches the prior Electron contract where timeout yields `null`).
     - `waitForReceiver` captures `{ payload, code }` in the send ref, submits a `"find-receiver"` task, awaits it, returns `outputs.endpoint` (or `null`/throws as above).
     - `sendToReceiver` reads the captured `{ payload, code }`, submits a `"send-payload"` task with `{ payload, code, endpoint }`, awaits it, returns `outputs.success` (false if nothing was captured; throws on task failure).
     - `cancelShareReceive` / `cancelShareSend` clear their refs and call `queue.cancelTasks("lan-share")`.
     - A `useEffect` cleanup calls `queue.shutdown()` on unmount.
   - Cast task `outputs` to the DTO result types from `api`.
   - Requirement: type-checks cleanly; covered by e2e (hooks are not unit tested).

7. **Export the hook from the UI package.** Edit `packages/user-interface/src/index.tsx` and add `export * from "./lib/use-lan-share-tasks";` alongside the other `./lib/*` exports. Requirement: `import { useLanShareTasks } from "user-interface"` resolves.

8. **Rewire the desktop platform provider.** Edit `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`:
   - Add `useLanShareTasks` to the existing `user-interface` import.
   - Delete the six `useCallback` definitions `startShareReceive`, `waitShareReceive`, `cancelShareReceive`, `waitForReceiver`, `sendToReceiver`, `cancelShareSend` (lines ~457-479). Keep `importSharePayload` unchanged.
   - Near the top of the component, add `const { startShareReceive, waitShareReceive, cancelShareReceive, waitForReceiver, sendToReceiver, cancelShareSend } = useLanShareTasks();`.
   - Leave the `platformContext` object literal (lines ~538-543) unchanged — the destructured names still satisfy it.
   - Requirement: type-checks; the existing dialogs are untouched.

9. **Rewire the mobile platform provider.** Edit `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`:
   - Add `useLanShareTasks` to the existing `user-interface` import.
   - Delete the six no-op `useCallback` share methods (lines ~183-202). Keep `importSharePayload` unchanged.
   - Add the same destructuring line as step 8 near the top of the component.
   - Leave the `platformContext` object literal (lines ~253-258) unchanged.
   - Update the provider's doc comment to note share/receive now run as background tasks (failing on the embedded engine until native networking host functions exist).
   - Requirement: type-checks.

10. **Remove the sharing logic from Electron main.** Edit `apps/desktop/src/main.ts`:
    - Delete the six IPC handlers `start-share-receive`, `wait-share-receive`, `cancel-share-receive`, `wait-for-receiver`, `send-to-receiver`, `cancel-share-send` (lines ~779-838) and the `IWaitForReceiverRequest` interface.
    - Delete the module-level `activeSender` and `activeReceiver` variables (lines ~73-77).
    - Delete the `lan-share` imports (`LanShareSender`, `LanShareReceiver`, `IReceiverEndpoint`) on lines ~27-28.
    - Keep the `import-share-payload` handler, `ISecretShareImportPayload`, `IImportSharePayloadRequest`, and the `IDatabaseSharePayload`/`ISecretSharePayload`/`IConflictResolution` imports from `api` (still used by import).
    - Requirement: `apps/desktop` type-checks with no unused-symbol errors.

11. **Full compile and test pass.** Run `bun run compile`, `bun run test`, and the relevant smoke tests (`bun run test:electron`). Fix any breakage. Requirement: everything in the Verify section passes.

## Unit Tests

- `packages/node-api/src/test/lan-share.worker.test.ts` (new). Use `jest.mock("lan-share", ...)` to substitute fake `LanShareReceiver`/`LanShareSender` classes so no real sockets are opened. Build an `ITaskContext` test double whose `isCancelled()` is controllable.
  - `receiveShareHandler` calls `receiver.start(code)` with the supplied code and returns `{ payload }` from `receiver.receive()`.
  - `receiveShareHandler` returns `{ payload: null }` when `receiver.receive()` resolves `null` (timeout).
  - `receiveShareHandler` calls `receiver.cancel()` when the context reports cancellation (drive with `jest.useFakeTimers()` and advance past `CANCEL_POLL_INTERVAL_MS`), and clears the interval afterwards.
  - `findReceiverHandler` returns `{ endpoint }` from `sender.waitForReceiver()` and returns `{ endpoint: null }` on timeout.
  - `findReceiverHandler` calls `sender.cancel()` on cancellation.
  - `sendPayloadHandler` constructs the sender with `data.payload`/`data.code`, calls `sender.send(data.endpoint)`, and returns `{ success }` reflecting the resolved value (cover both `true` and `false`).
- No unit tests for `useLanShareTasks` (a hook) or the providers (contexts) — covered by smoke tests per project convention.

## Smoke Tests

- Extend the Electron smoke suite (`bun run test:electron`) so the share/receive round trip exercises the new task path end to end. If an existing share smoke test exists under the desktop e2e harness, confirm it still passes after the refactor; if not, add an automated check that drives a receiver and a sender within one Electron run and asserts the payload is delivered (proving `receive-share` + `find-receiver` + `send-payload` work through `ElectronRendererQueueBackend` → main worker pool → utility worker).
- Add a check that cancelling mid-wait (calling `cancelShareReceive`/`cancelShareSend`) resolves the task and tears down sockets without leaking.
- Mobile behaviour is intentionally a runtime failure for now; document (do not assert a passing transfer) that dispatching `receive-share`/`find-receiver`/`send-payload` to the embedded engine yields a failed task because the handler is absent from `worker.bundle.js` and Node networking is unimplemented.

## Verify

- `bun run compile` type-checks the whole monorepo cleanly (no errors, no unused-symbol errors in `apps/desktop/src/main.ts`).
- `bun run test` passes, including the new `lan-share.worker.test.ts`.
- `bun run test:electron` passes, including the share round-trip smoke check.
- Grep confirms the six removed IPC channel strings no longer appear in `apps/desktop/src/main.ts` and that no source file still calls `electronAPI.invoke('start-share-receive' | 'wait-share-receive' | 'cancel-share-receive' | 'wait-for-receiver' | 'send-to-receiver' | 'cancel-share-send')`.
- `bun run build:bundle` (in `packages/mobile-worker`) still succeeds — the share handlers are deliberately NOT added to `mobile-worker-entry.ts`, so the browser-target bundle does not try to resolve `dgram`/`https`/`tls`.

## Notes

- `bun build --target=browser` hard-errors on Node built-in imports (verified: `error: Browser build cannot import Node.js builtin: "dgram"`). This is why the share handlers cannot be registered in `mobile-worker-entry.ts` yet, exactly like the other `node-api` handlers. The mobile path therefore fails at runtime with "No handler registered for task type" until a native networking seam lands. This matches the user's explicit instruction: do not implement host-bridge/native APIs now; an expected runtime error is acceptable.
- The send flow is split into two tasks (`find-receiver` then `send-payload`) to preserve the existing two-phase `waitForReceiver` → `sendToReceiver` platform interface, so the `share-database-dialog.tsx` and `receive-database-dialog.tsx` components need no changes. The discovery socket from `find-receiver` is closed before `send-payload` opens its own HTTPS connection; this is fine because `LanShareSender.send()` does not reuse the discovery socket, and the receiver keeps broadcasting/listening for the full timeout window.
- `IShareReceiverEndpoint` is defined in `api` rather than imported from `lan-share` to avoid `user-interface` and `api` taking a dependency on `lan-share` (which pulls in Node-only code). Structural typing makes it interchangeable with `lan-share`'s `IReceiverEndpoint` inside the handlers.
- The platform interface keeps `unknown` for the payload/endpoint parameters to avoid editing `IPlatformContext` and every implementer; the concrete DTO types are used only inside the hook and the handlers.
- `importSharePayload` is intentionally out of scope — it is a separate, non-networking concern (vault/config writes) and remains an Electron-main IPC handler and a mobile no-op for now.
- Desktop renderer dispatches tasks via `ElectronRendererQueueBackend` (set in `apps/desktop-frontend/src/app.tsx`), which proxies `addTask` over IPC to the main-process worker pool, so `new TaskQueue(...)` inside the shared hook runs on the Electron utility worker with full Node networking.
