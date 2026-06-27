# Step 7: Create `packages/mobile-frontend` and the `JsEngine` plugin JS interface

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

## How to check on Android

No Android-specific check at this step: the `JsEngine` plugin interface is TypeScript that runs in the WebView, covered by the unit test (`bun run test`) with a mocked Capacitor `registerPlugin`. It is exercised against the real Android native plugin only once Step 11 lands.

## Summary

Created the shared `packages/mobile-frontend` workspace package (`package.json`, `tsconfig.json`, `jest.config.js`, `src/index.ts`) holding the TypeScript that is identical across both mobile apps.

- `src/lib/js-engine-plugin.ts` — the `JsEngine` Capacitor plugin interface via `registerPlugin<IJsEnginePlugin>("JsEngine")`, with named interfaces for every payload: `IAddTaskOptions`, `ICancelTasksOptions`, `ITaskCompletedResult`, `ITaskCompletedEvent`, `ITaskMessageEvent`, `IJsEnginePlugin` (`addTask`, `cancelTasks`, `shutdown`, and the two `addListener` channels returning `PluginListenerHandle`). No inline anonymous object types.
- `src/test/js-engine-plugin.test.ts` — asserts the plugin registers under the name `JsEngine` (via a mocked `@capacitor/core`).

Verified: `bun run compile` and `bun run test` pass for the package. Both apps now depend on it (`workspace:*`).
