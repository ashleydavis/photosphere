# Step 15: Add the automated on-device background-task smoke tests

Prove that real tasks run in the engine on a device, end to end, with no manual UI run. Uses the mobile smoke harness from `plan-mobile-smoke-tests.md` (host control bridge + WebSocket into the app). Gated on the storage host functions (Step 13) existing.

## What to do

1. Add `test.sh` cases under the mobile smoke-tests `tests/` directory (for example `tests/N-background-task-hash/test.sh`), driven entirely from the host so they are automated.
2. On a booted Android emulator and iOS simulator, dispatch a real background task from the web app and assert:
   - the task completes with the expected result,
   - the streamed `taskMessage` progress events arrive in order,
   - `cancelTasks` cancels a running task.
3. On-device host-function smoke: exercise the real native host functions (storage read/write, hashing) end to end on each platform and confirm the result and streamed messages.
4. Parallelism smoke test: with a pool size of at least 2, dispatch two long-running tasks and assert from interleaved/streamed messages and timing that both run concurrently; add a pool-size-1 variant asserting serial execution.
5. Add native build checks for both platforms with the new plugin, runner, and host functions.

## Tests

- The smoke tests above are themselves the test output of this step. Wire them so they run via the project's `bun run` smoke-test scripts (no direct shell-script invocation).

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
