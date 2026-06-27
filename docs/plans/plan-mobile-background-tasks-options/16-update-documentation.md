# Step 16: Update documentation

Revise the documentation drafted in Step 1 to reflect the final state of the code, including anything that changed during implementation.

## What to do

1. Update `docs/background-tasks.md` (the mobile / embedded-engine section) so it matches what actually shipped: the round trip, the host bridge, the NOT IMPLEMENTED rule, the concurrency model and `POOL_SIZE`, and the security notes (path sandbox, packaged-asset-only bundle). Correct anything that diverged from the Step 1 draft.
2. Update the CLAUDE.md Architecture/Mobile section to state that mobile runs background tasks in an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android) driven by the native `JsEngine` plugin via a host bridge, with `packages/mobile-frontend` and `packages/mobile-worker` as the shared packages.
3. Confirm `docs/mobile-host-bridge-checklist.md` is current: every host function used by a shipped handler is `implemented` and `tested` on both platforms, and any remaining `stubbed` function throws the NOT IMPLEMENTED error rather than failing silently.

## Final verify

- Run all unit tests (TS and native) and confirm they pass, including the NOT IMPLEMENTED guard tests, the dispatcher tests (FIFO, idle-slot, concurrency cap, size-1 serial, cancel-pending), the fire-and-forget/listener tests, the large-payload test, and the path-sandbox tests.
- Run the QuickJS and JavaScriptCore parity smoke tests against `worker.bundle.js` and confirm a real handler returns the expected result under both engines, and that the unimplemented-host-function case fails with the exact NOT IMPLEMENTED message.
- Build the Android and iOS projects and confirm both compile.
- Run the automated on-device background-task smoke test on a booted Android emulator and iOS simulator.
- Run the full repo `bun run test:all` to confirm desktop/CLI task paths are unaffected.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
