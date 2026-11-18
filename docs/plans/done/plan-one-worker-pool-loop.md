# One worker pool loop for the app, the CLI and the tests

## Overview

Ziggy has one worker pool (`WorkerPool` in `ziggy/packages/ziggy/core/src/lib/worker-pool.zig`) but three separate loops feed it the messages its workers send: Ziggy's core main loop (`mainThread` in `core.zig`), the Photosphere CLI's own pool `WorkerPoolBun` (`photosphere/apps/cli-zig/src/lib/worker-pool.zig`, which repeats the pool's dispatch, receive, cancel and shutdown logic) and the test "mock" (`ziggy/packages/ziggy/core/src/lib/task-queue/mock-worker-pool.zig`, which is Ziggy's real pool plus a loop and lives in the library's product source). This plan adds one standalone loop to Ziggy's product code, `TaskPool`, gives `WorkerPool` the task timeouts the CLI needs, makes the CLI and every test use `TaskPool`, and deletes `WorkerPoolBun` and the mock. Ziggy's core main loop keeps multiplexing its own queue (frontend, native app, remote control and workers) and hands worker messages to the same `WorkerPool`, so the pool logic exists once.

## Issues

## Steps

- [x] 1. Create the worktrees. Ziggy: check `$(git -C ziggy rev-parse --git-common-dir)/hooks/pre-commit` links to `.githooks/pre-commit` and run `bun run install-hooks` if not; then `git -C ziggy worktree add -b one-worker-pool-loop .claude/worktrees/one-worker-pool-loop main`. Photosphere: `git -C photosphere worktree add -b one-worker-pool-loop .claude/worktrees/one-worker-pool-loop zig-2`. Run `mise trust` on each worktree's `mise.toml`, then `mise exec -- bun install` in each worktree. In the Photosphere worktree, change the `ziggy` dependency in `build.zig.zon` from `.url`/`.hash` to `.path = "../../../../ziggy/.claude/worktrees/one-worker-pool-loop"` so every Photosphere build and test in this plan uses the local Ziggy. This edit is never staged (see Release).

   Done: the Ziggy hook already linked to `.githooks/pre-commit`. Both worktrees were made on branch `one-worker-pool-loop` (Ziggy from `main` at 632c9bc, Photosphere from `zig-2` at 8169f75fa), `mise trust` and `mise exec -- bun install` ran in each, and `build.zig.zon` points `ziggy` at the Ziggy worktree with `.path`.

- [x] 2. Ziggy, `worker-pool.zig`: separate a worker's sender id from its display id. `IWorkerState` gains `sender_id: u32` (the id its messages reach the main queue under) next to `workerId` (the number in log lines). `WorkerPool.next_worker_id` becomes `next_sender_id`; a new worker gets the next sender id and the lowest display id not in use. `receive` matches `message.from` against `sender_id`. Unit test: two workers get display ids 1 and 2 and their messages reach the right state.

   Done: `createWorker` takes the display id and returns the state; `dispatchTask` passes `lowestFreeWorkerId()`. A child's `queued_by` is now the parent worker's sender id, so a child's end never reaches the replacement of an abandoned parent. Test "two workers get display ids 1 and 2 and their messages reach the right state" added. The existing test "a worker that cannot start ..." asserted the failed worker was gone by `workerId != 1`; its replacement now reuses display id 1, so it asserts `sender_id != 1` (the same worker, identified the way the pool now identifies it).

- [x] 3. Ziggy, `worker-pool.zig`: task timeouts.
   - `WorkerPoolOptions` gains `task_timeout_ms: ?u64 = null`. The app core leaves it null.
   - `IWorkerState` gains `task_started_ms: ?i64`, set in `dispatchTask` from the awake clock and cleared when the task ends.
   - `pub fn nextTaskDeadline(self) std.Io.Timeout`: the earliest running task's deadline, or `.none`.
   - `pub fn failTimedOutTasks(self, io, allocator, timers, log) void`: for each task past its deadline, logs `[Task Queue] Task <id> timed out after <ms>ms` with `log.@"error"`, calls `Worker.abandon` on its worker, records the worker's `sender_id` in a new `abandoned_sender_ids` list, ends the task through `finish` as failed with the error message `Task timeout`, starts a replacement with the same display id and a new sender id, and calls `tryDispatchPending`.
   - `receive` returns true and frees nothing for a message whose sender is in `abandoned_sender_ids` (it is dropped), so a late message from an abandoned thread is never taken for its replacement's.
   - `pub fn hasAbandonedWorkers(self) bool`.
   - Unit tests in `core/src/test/worker-pool.test.zig`, ported from the CLI's `worker-pool.test.zig` with the same assertions: "times out a task, reports it failed and replaces the worker" (failed count 1, the next task's output, the timeout line, one worker whose display id is 1) and "a worker abandoned at its timeout can still send once the pool is gone, and what it sends is dropped". Use a slow test task in `core/src/test/test-tasks.zig` (add one if none sleeps for a given time).

   Done as listed. The replacement takes the abandoned worker's place in `workers` and keeps its `tasksProcessed`. The existing "sleep" task of `test-tasks.zig` sleeps for the given ms, so no task was added. Decision: "times out a task, reports it failed and replaces the worker" is in `worker-pool.test.zig` with the CLI's assertions (the echo task's output there is its input, `"after"`). The CLI's abandoned-worker test asserts on the queue the pool leaves closed, which is `TaskPool.deinit`'s job, so its exact port is in `task-pool.test.zig`; `worker-pool.test.zig` has "a message an abandoned worker sends after its timeout is dropped", which checks `receive` takes the abandoned worker's late task end and reports no second end.

- [x] 4. Ziggy, `worker-pool.zig`: `LogHandler.write` gains the worker's display id and its current task id: `write(user_data, worker_id: u32, task_id: ?[]const u8, message_json: []const u8)`. `handleWorkerMessage` passes `state.workerId` and `state.currentTask.id` when there is one. The default path (no handler) is unchanged. Unit test: a log handler receives the worker id and the task id of the running task, and null between tasks.

   Done, with test "a log handler receives the worker id and the task id of the running task, and null between tasks" (the between-tasks line is posted under the worker's sender id while it is idle).

- [x] 5. Ziggy, `worker-pool.zig`: `pub fn stopWorkers(self, io) void` for a process that is ending: posts `cancel-tasks` for each running task's source and `shutdown` to every worker, joins every worker thread that was not abandoned, frees nothing. Unit test: after `stopWorkers` with a running blocking task, every non-abandoned worker thread has ended.

   Done, with test "stopWorkers cancels the running task and returns once every worker thread has ended". Decision: `stopWorkers` also empties `workers` (as the CLI's `stopWorkers` did), so the CLI's two shutdown tests keep their `workers.items.len == 0` assertion.

- [x] 6. Ziggy: add `packages/ziggy/core/src/lib/task-pool.zig` with `pub const TaskPool`, the standalone loop for a program or test with no Ziggy core main loop. Make it from `task-queue/mock-worker-pool.zig` plus the parts below, and export it from the `ziggy` module as `ziggy.task_pool`.
   - Holds a heap-allocated `MessageQueue` and a `WorkerPool` made on it.
   - `pub fn init(allocator, options: WorkerPoolOptions) !*TaskPool`.
   - `pub fn waitForMessage(self, io, allocator, timers, log) void`: takes one message from the queue with the earlier of `timers.nextTimeout()` and `pool.nextTaskDeadline()` as the timeout, hands it to `pool.receive` (a message from no worker of the pool panics, as `waitForWorkerMessage` does), then calls `pool.failTimedOutTasks` and runs the timers that are due. This replaces `WorkerPool.waitForWorkerMessage`.
   - `pub fn drainMessages(self, io, allocator, timers, log) void`: the same without waiting, handling every message already queued (replaces the CLI's `handleQueuedMessages`).
   - `pub fn queueBackend(self) IQueueBackend`: returns the pool's IQueueBackend with `waitForMessage` routed to `TaskPool.waitForMessage`.
   - `pub fn stopWorkers(self, io) void`: calls `pool.stopWorkers`.
   - `pub fn deinit(self, io, allocator, timers, log) void`: waits while `pool.isBusy()`, calls `pool.shutdown`, then frees the queue, unless `pool.hasAbandonedWorkers()`, in which case it closes the queue and leaves it allocated so an abandoned thread's late post is dropped.
   - Unit tests in `core/src/test/task-pool.test.zig`: every test of `MockWorkerPool` moves here unchanged apart from the type name, plus "a pool whose maximum is 0 workers leaves its task pending" (ported from the CLI's NaN test, with the same two assertions).

   Done. `queueBackend` returns the pool's functions with the pool as the pointer and `waitForMessage` reaching the `TaskPool` through `@fieldParentPtr`; `WorkerPool.queueBackendVTable(waitForMessage)` builds that table. The four pool tests of `queue-backend.test.zig` moved to `task-pool.test.zig`; added "waitForMessage fails a task that runs past its timeout while it waits", "drainMessages hands the pool the messages already sent without waiting for more", the 0-worker test (it cancels its task at the end so `deinit` does not wait on it) and the abandoned-worker port. The mock's `getPendingTaskTypes`, `cancelTasks`, `handlers` and `IBaseContext` were not carried over, as only tests used them; tests read `pool.pool.pending_tasks`, call `queueBackend().cancelTasks` and list `TaskHandlerEntry` values. Decision: the pool's failing event callbacks now log "Error in task message callback" and "Error in any task message callback" (was "event"), the CLI's wording, so the CLI test of them keeps its assertion; Ziggy's test of those lines checks `TaskQueue`'s own callbacks, whose wording is unchanged.

- [x] 7. Ziggy: point every user of `MockWorkerPool` at `TaskPool`: `core/src/test/queue-backend.test.zig`, `core/src/test/task-queue/concurrency.test.zig`, `core/src/test/task-queue/task-queue.test.zig` and any other file `grep -rn mock_worker_pool packages apps` finds. Remove `WorkerPool.waitForWorkerMessage` and the `mock_worker_pool` export from `task-queue.zig`. Update the header comment of `worker-pool.zig`: the IQueueBackend is for `TaskPool`. Run `bun run compile`, `bun run test:zig` and `bun run test:smoke` in the Ziggy worktree; all pass.

   Done. `WorkerPool.queueBackend` went too. `bun run compile` exited 0. `zig build test`: 843 of 845 passed, 2 skipped. `bun run test:smoke`: 35 passed, `37-new-window` failed; run alone it failed again, then passed on a third run alone. It is rechecked in Verify.

- [x] 8. Photosphere CLI: add `apps/cli-zig/src/lib/worker-log.zig` holding the CLI's worker log line writing taken from `WorkerPoolBun`: `writeWorkerLog`, `writeToolStream`, `prefixMessage` and a `logHandler(log, tools_shown) worker_pool.LogHandler` whose `write` calls `writeWorkerLog` with the worker id and task id step 4 passes. Move `worker-pool-log.test.zig` to test this file with the same assertions.

   Done. `LogHandler.write` has no log argument, so `logHandler(allocator, log, toolsShown)` allocates a small target holding the log and the `--tools` flag. `worker-log.test.zig` holds the four tests with the same assertions, plus a test of the handler. The old `worker-pool-log.test.zig` goes in Clean up with `WorkerPoolBun`.

- [x] 9. Photosphere CLI, `init-cmd.zig`: replace `WorkerPoolBun.init` with `ziggy.task_pool.TaskPool.init` given:
   - `max_workers`: the parsed `--workers` value, or the CPU count, converted from the f64 `jsNumber` result to u32 with NaN, infinities and values below 1 giving 0, and values above `std.math.maxInt(u32)` giving that maximum.
   - `task_timeout_ms`: `setTimeoutDelay(timeout)` as u64.
   - `tasks`: `node_api.task_handlers.taskEntries(media_tools.ThreadTools, registerMediaSources)`, with `registerMediaSources` moved into `init-cmd.zig`.
   - `describe_error`: `utils.errors.errorMessage`.
   - `worker_options`: verbose, tools and sessionId from the options, `maxConcurrentChildTasks = 10`.
   - `on_log`: `worker_log.logHandler(log, options.tools orelse false)`.
   `ICleanupContext.workerPool` becomes `*TaskPool`; `cleanupOnTermination` calls `stopWorkers(io)`. `setQueueBackend` and `ICommandContext.workerPool` take `pool.queueBackend()`. Register one completion callback on that backend that writes `Task <id> failed: <error name>: <error message>` with `writeOutputLine` for a failed task when `log.verboseEnabled()`.

   Done. `maxWorkers(value)` does the conversion and rounds a fraction up, as the TypeScript pool started workers while it had fewer than the value. `describe_error` is a wrapper of `utils.errors.errorMessage`, whose return type is not optional. `worker_options` also keeps the config and state paths it had. The callback is `writeFailedTaskLine`, public so the ported test registers it. Tests "maxWorkers converts the --workers number ..." and "writeFailedTaskLine writes a failed task's error when verbose logging is on" added.

- [x] 10. Photosphere CLI tests: port every pool test in `apps/cli-zig/src/test/worker-pool.test.zig`, `worker-pool-long-error.test.zig` and the pool tests of `cli-a-infrastructure.test.zig` to `TaskPool` with the same assertions; `handleQueuedMessages` calls become `drainMessages`. Tests that duplicate a Ziggy test after the move (the worker that fails to start, the timeout, the abandoned worker, the 0-worker pool) are listed for Clean up. Update the two casts in `init-cmd.test.zig` to `*TaskPool`.

   Done. The tests build pools with `createPool` in `worker-pool.test.zig`; callbacks and tasks go through `queueBackend()`; the shutdown tests call `stopWorkers` (the CLI's shutdown path), and the one on the leak-counting allocator moved its pool to its arena because `stopWorkers` frees nothing. The verbose failed-task test registers `init_cmd.writeFailedTaskLine`, as `initContext` does. The four tests listed for Clean up and the timeout message test stay on `WorkerPoolBun` until then, through helpers that take either pool. The casts in `init-cmd.test.zig` go through `@fieldParentPtr` because the backend's pointer is the `WorkerPool` inside the `TaskPool`.

- [x] 11. Photosphere node-api tests: in `packages-zig/node-api-zig/src/test/test-environment.zig`, `task-data-dir.test.zig` and `production-queue-backend.zig`, replace `ziggy.task_queue.mock_worker_pool.MockWorkerPool` with `ziggy.task_pool.TaskPool`, mapping `MockWorkerPool.init(allocator, maxConcurrent, baseContext, taskTypes)` to `TaskPool.init` with the same task types, session id and child limit. Run `mise exec -- zig build test --summary all` and `bun run test:cli:zig` in the Photosphere worktree; all pass.

   Done. `test-environment.zig` has `createPool(allocator, workers, tasks)` (session "test-session", two child tasks, the mock's error describer), used by all three files. `import.test.zig` named `MockWorkerPool` only in a comment, which was reworded. `zig build test --summary all`: 4306 of 4312 passed, 6 skipped. `bun run test:cli:zig`: all 133 passed.

- [x] 12. Write the docs.
    - Ziggy `docs/user-guide/tasks.md`: the "Code written against the task queue" section says a program or test with no Ziggy core runs tasks with `TaskPool`, which waits for worker messages while its caller waits, and can fail a task that runs past a timeout by abandoning and replacing its worker.
    - Ziggy `docs/user-guide/threads.md`: the main thread section says the core's loop hands worker messages to the pool, and that `TaskPool` is the same for a program with no core.
    - Ziggy `docs/upgrade-notes.md`: under the next version, `MockWorkerPool` is replaced by `ziggy.task_pool.TaskPool` and `LogHandler.write` takes the worker id and task id.
    - Photosphere `docs/threads.md` "The Zig CLI" and `docs/tasks.md` "The CLI": the CLI runs its tasks on Ziggy's `TaskPool` with a task timeout from `--timeout`, replacing its own pool.

   Done in all five files. Photosphere's `docs/threads.md` also gives the CLI's new log lines and the end-of-process stop.

- [x] 13. No commits: the changes stay in the two worktrees' working copies for the human to review. Nothing is committed, pushed or merged. The Photosphere `build.zig.zon` keeps its `.path` to the Ziggy worktree, because Photosphere's code now needs `TaskPool`, which only the local Ziggy has.

   Done. This step first said to commit both worktrees, and a Ziggy commit was made before the human halted the commits. On the human's request it was undone with `git reset HEAD~1`, so Ziggy's branch is at 632c9bc with every change unstaged. The Photosphere commit was stopped before it was recorded, so its branch is at 8169f75fa and its changes are still staged, apart from `build.zig.zon` and this plan. Nothing was pushed or merged.

- [x] 14. Clean up: delete `photosphere/apps/cli-zig/src/lib/worker-pool.zig` (`WorkerPoolBun`), `apps/cli-zig/src/test/worker-pool-log.test.zig`, `ziggy/packages/ziggy/core/src/lib/task-queue/mock-worker-pool.zig` and the CLI tests whose subject moved to Ziggy (step 10), with the `WorkerPoolBun` paths of the test helpers that let them run, the `worker_pool` export of `apps/cli-zig/index.zig` and the `mediaTools` imports left unused.

   Done. Deleted `worker-pool.zig`, `worker-pool-log.test.zig` and `mock-worker-pool.zig`. Removed from `worker-pool.test.zig` the tests "a worker that fails to start ...", "times out a task ...", "a worker abandoned at its timeout ...", "the timeout message writes ..." and the "slow" task only they used; from `cli-a-infrastructure.test.zig` "a pool that can never create a worker leaves the task pending" and the unused `media_tools` import. The helpers take `*TaskPool` again. Verify: Ziggy `bun run compile` exit 0; `zig build test` 843 of 845 passed, 2 skipped; `bun run test:smoke` 36 passed, 0 failed (`37-new-window` included); `bun run test:zig:android` core 515 passed, 1 skipped, 0 failed, and every other module passed. Photosphere `bun run tev`: all 6 scripts passed (compile, test, test:cli:zig, test:ziggy, test:ziggy:and, test:zig). The plan's grep finds 0 matches. Evidence is in each worktree's `tmp/evidence/`.

## Unit Tests

- `WorkerPool`: sender and display ids; timeout and replacement keeping display id 1; abandoned sender's messages dropped; log handler receives worker id and task id; `stopWorkers`.
- `TaskPool`: every former `MockWorkerPool` test; `waitForMessage` fails a timed-out task while waiting; `drainMessages`; a pool of 0 workers leaves its task pending; `deinit` closes and keeps the queue after an abandoned worker.
- CLI `worker-log.zig`: the four tests of `worker-pool-log.test.zig`.
- CLI `init-cmd.zig`: the `--workers` conversion (NaN, 0, 2.5, a large number) and the verbose failed-task line.

## Smoke Tests

- Ziggy `bun run test:smoke`: the app core's tasks still run, report and cancel.
- Photosphere `bun run test:cli:zig`: every CLI command that runs tasks (add, verify, check, sync, replicate) through `TaskPool`.
- Photosphere `bun run test:ziggy` and `bun run test:ziggy:and`: the app is unchanged in behaviour.

## Verify

- Ziggy worktree: `bun run compile`, `bun run test:zig`, `bun run test:smoke`, and `bun run test:zig:android` (the Ziggy CLAUDE.md requires the mobile suite for a core change). The iOS suites need macOS and run only in CI.
- Photosphere worktree, built against the local Ziggy by step 1: `bun run tev`.
- `grep -rn "WorkerPoolBun\|MockWorkerPool\|mock_worker_pool" ziggy photosphere --include=*.zig` (outside zig-pkg and .zig-cache) finds nothing.

## Notes

- The human answered no to a documentation step first, so there is no review stop.
- The work runs in worktrees named `one-worker-pool-loop`, branched from Ziggy `main` and Photosphere `zig-2`, and is left uncommitted there for the human to review. Nothing is committed, pushed, merged or released.
- A Ziggy release is never needed: Photosphere builds against the Ziggy worktree through the unstaged `.path` dependency, so its pre-commit hook tests the real change.
- Ziggy's core main loop is not replaced by `TaskPool`: its queue also carries frontend, native app and remote control messages. It already hands worker messages to `WorkerPool.receive`, which is the one copy of the pool logic.
- CLI behaviour changes: a worker that cannot start logs Ziggy's `Worker <n> could not start: <reason>` instead of `Error from worker <n>`; the verbose failed-task line loses its `[W<id>:<task>]` prefix; the timeout line prints whole milliseconds (`--timeout 0.5` is reported as 1ms, as `setTimeoutDelay` rounds it); a finished child task is told only to the worker that queued it, not broadcast to every worker. The CLI test "the timeout message writes the timeout as a template string writes a number" is deleted because the fractional timeout it tested no longer exists.
- `TaskPool` is product code used by the CLI, so it is not a mock and does not break the rule against test code in product files.
