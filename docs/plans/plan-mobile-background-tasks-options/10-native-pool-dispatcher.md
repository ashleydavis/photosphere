# Step 10: Implement the native engine pool and dispatcher (both platforms)

Implement the shared pool structure and dispatcher that both platform engine hosts plug into, modelled on the desktop worker pools (especially `apps/cli/src/lib/worker-pool-bun.ts`, with `apps/desktop/src/lib/worker-pool-electron-main.ts`).

## What to do

1. The pool holds N engine threads where N is the `POOL_SIZE` build-time constant (default 3, defined once per platform, documented as the only source of truth; size 1 is a supported serial configuration).
2. Maintain the shared, lock-guarded structures: a pending-task FIFO, a running-task map, a cancelled-source set, and the single owned `sessionId` (generated once when the pool initialises and passed into every engine's `runTask` context).
3. Dispatcher: `addTask` enqueues; the dispatcher assigns the next pending task to any idle engine and reassigns when an engine frees, giving true parallelism up to the pool size.
4. Cancellation by source across the whole pool: `cancelTasks(source)` adds the source to the cancelled set (updating atomic/volatile flags) and drops matching pending tasks; running tasks observe it via `isCancelled`. `isCancelled` reads the atomic flag without taking the lock; `sendMessage` takes a short lock only around the `notifyListeners` hand-off.
5. Implement `shutdown`: stop the dispatcher, drain/abandon the pending FIFO, signal running engines to stop, tear down each engine thread (terminate `ExecutorService` / dispatch queues, dispose contexts), remove host bridges, and clear the shared structures.

## Tests

- Native pool dispatcher unit tests on both platforms (drive the dispatcher directly with stub engines, no JS context needed):
  - FIFO ordering of pending tasks,
  - idle-slot assignment (next pending goes to the first idle engine),
  - reassignment when an engine frees,
  - concurrency cap (no more than `POOL_SIZE` engines run at once),
  - `POOL_SIZE`-1 serial execution (tasks run strictly one after another),
  - cancel-drops-pending (cancelling a source removes its still-pending tasks and they never dispatch),
  - cancellation of a pending (not yet running) task as a distinct case from cancelling a running task.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
