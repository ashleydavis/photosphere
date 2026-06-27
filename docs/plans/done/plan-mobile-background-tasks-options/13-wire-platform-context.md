# Step 13: Wire the mobile platform context to the embedded engine

Replace the no-op stubs in `platform-provider-mobile.tsx` so UI that drives tasks through the platform context (notably the Job Manager) works on mobile.

## What to do

1. In `packages/mobile-frontend` (the shared `platform-provider-mobile` logic), replace the current no-op stubs:
   - `cancelTasks(source)` calls `JsEngine.cancelTasks({ source })` (the same path `EmbeddedJsQueueBackend.cancelTasks` uses).
   - `onTaskMessage` / `onTaskComplete` subscribe to the plugin's `taskMessage` / `taskCompleted` events.
2. Replace the byte-identical `platform-provider-mobile.tsx` in both apps with thin imports from the shared package.
3. This is required for the Job Manager (`plan-job-manager.md`) Cancel button, which calls `platform.cancelTasks(sourceTag)`; without this wiring that cancel is a no-op on mobile.

## Tests

- Unit test (with the mock `JsEngine` plugin): assert `platform.cancelTasks(source)` forwards to `JsEngine.cancelTasks`, and that `platform.onTaskMessage` / `platform.onTaskComplete` fire when simulated `taskMessage` / `taskCompleted` events arrive.

Run all tests and confirm they pass before marking this step complete.

## How to check on Android

No Android-specific check at this step: the platform-context wiring is TypeScript in the WebView, covered by the unit test (`bun run test`) with a mock `JsEngine`. It is exercised on Android through the Job Manager Cancel path in the Step 14 on-device smoke.

## Summary

Moved the byte-identical `platform-provider-mobile.tsx` into `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx` (deleted both app copies; `app.tsx` now imports `PlatformProviderMobile` from `mobile-frontend`).

Wired the three task callbacks that previously were no-ops, via `src/lib/mobile-platform-tasks.ts`:
- `cancelTasks(source)` → `cancelMobileTasks(source)` → `JsEngine.cancelTasks({ source })` (the Job Manager Cancel path).
- `onTaskMessage(handler)` → `subscribeMobileTaskMessage` (subscribes to the plugin `taskMessage` event; sync unsubscribe that removes the async handle once resolved).
- `onTaskComplete(handler)` → `subscribeMobileTaskComplete` (same for `taskCompleted`).

The task bindings are factored into standalone functions so they unit-test without rendering React. Tests (`src/test/mobile-platform-tasks.test.ts`): `cancelMobileTasks` forwards to `JsEngine.cancelTasks`; `subscribeMobileTaskMessage` / `subscribeMobileTaskComplete` fire on simulated events and remove the handle on unsubscribe. Verified via `bun run test`.
