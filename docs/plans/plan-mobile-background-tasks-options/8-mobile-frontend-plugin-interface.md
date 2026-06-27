# Step 8: Create `packages/mobile-frontend` and the `JsEngine` plugin JS interface

Create the shared frontend workspace package and the Capacitor plugin JS interface used by both mobile apps.

## What to do

1. Add `packages/mobile-frontend` as a `workspace:*` package (with `src/test`). It will hold the TypeScript that is identical across both mobile apps: `EmbeddedJsQueueBackend` (next step), the `JsEngine` plugin interface, and shared `platform-provider-mobile` logic (later step).
2. Implement the `JsEngine` Capacitor plugin JS interface via `registerPlugin`, exposing:
   - `addTask({ taskId, type, data, source })`
   - `cancelTasks({ source })`
   - `shutdown()`
   - `addListener("taskCompleted", ...)` and `addListener("taskMessage", ...)` (both async, returning `PluginListenerHandle`).
3. Define the named TypeScript interfaces for the plugin and its event payloads (no inline anonymous object types).

## Tests

- Unit test for the plugin interface wiring: with a mocked Capacitor `registerPlugin`, assert the interface exposes `addTask`, `cancelTasks`, `shutdown`, and the two `addListener` channels with the expected payload shapes. (The behavioural backend tests come in the next step.)

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
