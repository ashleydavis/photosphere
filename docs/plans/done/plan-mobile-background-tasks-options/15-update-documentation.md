# Step 15: Update documentation

Revise the documentation drafted in Step 1 to reflect the final state of the code, including anything that changed during implementation.

## What to do

1. Update `docs/background-tasks.md` (the mobile / embedded-engine section) so it matches what actually shipped: the round trip, the host bridge, the NOT IMPLEMENTED rule, the concurrency model and `POOL_SIZE`, and the security notes (path sandbox, packaged-asset-only bundle). Keep it high level and free of plan-file links and any separate checklist document. Correct anything that diverged from the Step 1 draft.
2. Update the CLAUDE.md Architecture/Mobile section to state that mobile runs background tasks in an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android) driven by the native `JsEngine` plugin via a host bridge, with `packages/mobile-frontend` and `packages/mobile-worker` as the shared packages.
3. Confirm the host-function inventory in the plans is current: every host function used by a shipped handler is `implemented` and `tested` on both platforms, and any remaining `stubbed` function throws the NOT IMPLEMENTED error rather than failing silently.

## Final verify

- Run all unit tests (TS and native) and confirm they pass, including the NOT IMPLEMENTED guard tests, the dispatcher tests (FIFO, idle-slot, concurrency cap, size-1 serial, cancel-pending), the fire-and-forget/listener tests, the large-payload test, and the path-sandbox tests.
- Run the QuickJS and JavaScriptCore parity smoke tests against `worker.bundle.js` and confirm a real handler returns the expected result under both engines, and that the unimplemented-host-function case fails with the exact NOT IMPLEMENTED message.
- Build the Android and iOS projects and confirm both compile.
- Run the automated on-device background-task smoke test on a booted Android emulator and iOS simulator.
- Run the full repo `bun run test:all` to confirm desktop/CLI task paths are unaffected.

## How to check on Android

- Build the Android project: wrap `apps/android-frontend/android/gradlew assembleDebug` as a `bun run` script and confirm it compiles with the plugin, runner, and host functions.
- With an Android emulator booted, run `bun run test:android` and confirm the on-device background-task smoke passes end to end.
- Confirm the Android status in the plans' inventory is `implemented`/`tested` for every host function a shipped handler uses, with any remaining `stubbed` function throwing NOT IMPLEMENTED.

Run all tests and confirm they pass before marking this step complete.

## Summary

Updated the docs to match what shipped in this infrastructure layer:
- `docs/background-tasks.md` — replaced the "forward-looking" caveat with the current state, and rewrote the "Node APIs and the host bridge" section to state that Node.js APIs are **not** implemented/shimmed here: a background task calling a Node.js function reports NOT IMPLEMENTED, with native-backed implementations (fs/hashing/media) deferred to later layers. Noted that `sendMessage`/`isCancelled` are the working infrastructure host functions. Kept the round-trip, NOT IMPLEMENTED rule, concurrency/`POOL_SIZE`, and security sections.
- `CLAUDE.md` — the Architecture/Mobile bullet now states that mobile runs background tasks in an embedded JS engine (JavaScriptCore/QuickJS) via the native `JsEngine` plugin and a host bridge, names `packages/mobile-frontend` and `packages/mobile-worker`, and records the NOT IMPLEMENTED rule.

Host-function inventory status: `sendMessage` / `isCancelled` are implemented (infrastructure); `sha256` and all fs/media host functions report NOT IMPLEMENTED on both platforms (no native Node-function implementations in this layer, by decision).
