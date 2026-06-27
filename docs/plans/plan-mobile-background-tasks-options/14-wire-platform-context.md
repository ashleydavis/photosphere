# Step 14: Wire the mobile platform context to the embedded engine

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

## Summary

_To be completed when this step is implemented._
