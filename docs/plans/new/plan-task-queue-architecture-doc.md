# Inventory the task, queue, worker and cancellation architecture and document it

## Overview

Tasks are queued through one interface, `IQueueBackend`, but six different implementations sit behind it and each one schedules, runs and cancels tasks differently. Nobody has written down what those differences are. That gap has already cost real bugs: the mobile engine remembered a cancelled source forever, so a second replication or a second S3 listing was silently dropped, and it took a smoke test failure to find it. `apps/dev-frontend/src/lib/websocket-queue-backend.ts` currently hands tasks an `isCancelled` that always returns `false`, which means cancellation may be a no-op on that platform and nothing says so.

This plan produces one document, `docs/task-queue-architecture.md`, that inventories every backend, states for each how tasks are scheduled, how workers are hosted, and exactly what cancellation does, and shows the differences in Mermaid diagrams. The work is deliberately split into read-and-record steps followed by write-up steps, so the document describes what the code actually does rather than what it is assumed to do. Where the inventory turns up a genuine inconsistency, the document records it in a "Known divergences" section rather than fixing it: fixes are separate work with their own tests.

`docs/background-tasks.md` already covers how to add a task type and how the mobile host bridge works. The new document must not repeat that; it covers scheduling, worker hosting and cancellation across platforms, and the two link to each other.

## Issues

## Steps

Each step that changes a checked-in file must leave `bun run compile` clean. Steps 1 to 7 only read code and write notes to a scratch file, so they produce no compile or test surface of their own. Step 12 is the verification step.

### Step 1: Set up the inventory scratch file

Create a scratch notes file outside the repository (in the session scratchpad directory, not in `docs/`) to accumulate findings from steps 2 to 7. It is working material and must never be committed. Each finding is recorded as: backend name, file path, line reference, and the observed behaviour in one sentence.

### Step 2: Inventory the shared core

Read and record from `packages/task-queue/src/lib/`:

- `queue-backend.ts` — the `IQueueBackend` interface, every method, and the `setQueueBackend` / `getQueueBackend` process-singleton pattern.
- `task-queue.ts` — the `TaskQueue` class: the `source` field set in the constructor, `addTask`, `awaitTask`, the `onTaskAdded` / `onTasksCancelled` subscriptions, and `shutdown()` calling `backend.cancelTasks(this.source)`. Record that shutdown is how cancellation is normally triggered, since this is the non-obvious fact behind several bugs.
- `types.ts` — `ITaskResult`, `TaskStatus`, `WorkerTaskCompletionCallback`, `TaskMessageCallback`, `UnsubscribeFn`.
- `task-context.ts` — the context handed to a handler, in particular `isCancelled`.
- `worker.ts` and `worker-queue-backend.ts` — how a worker queues a child task by posting `queue-task` back to its host, and how completions are routed to it.

### Step 3: Inventory the CLI backend

Read `apps/cli/src/lib/worker-pool-bun.ts` and record: how workers are spawned (Bun `Worker`), the pool size and where it comes from, how a task is dispatched to an idle worker, how `cancelTasks` at line ~726 marks running tasks and drops pending ones, how `isCancelled` reaches a running handler, and whether a cancelled source is remembered after the cancel completes.

### Step 4: Inventory the Electron backends

Read and record both halves of the desktop path:

- `apps/desktop/src/lib/worker-pool-electron-main.ts` — utility-process workers, dispatch, and `cancelTasks` at line ~905.
- `apps/desktop-frontend/src/lib/electron-renderer-queue-backend.ts` — the renderer-side proxy, which IPC channel carries `addTask` / `cancelTasks` / completions, and `cancelTasks` at line ~164.
- `apps/desktop/src/main.ts` — where `setQueueBackend` is called and the pool is constructed.
- `apps/desktop/src/lib/test-control-server.ts` — only where it touches the queue, since the smoke tests drive it.

Record explicitly that the renderer holds no queue state: it is a proxy, and the authority is the main process.

### Step 5: Inventory the mobile backend

Read and record the whole mobile chain:

- `packages/mobile-frontend/src/lib/embedded-js-queue-backend.ts` — the WebView-side backend, its `cancelTasks` at line ~174 delegating to the plugin, and the `taskCompleted` event path back.
- `packages/mobile-frontend/src/lib/js-engine-plugin.ts` — the plugin interface.
- `packages/mobile-worker/mobile-worker-entry.ts` — the engine-side entry point and handler registration.
- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/`: `JsEnginePlugin.java`, `EnginePool.java`, `PooledTask.java`, `CancellationState.java`, `TaskEngine.java`, `QuickJsTaskEngine.java`.
- `apps/ios-frontend/ios/App/App/JsEngine/`: `JsEnginePlugin.swift`, `EnginePool.swift`, `PooledTask.swift`, `TaskEngine.swift`, `JavaScriptCoreTaskEngine.swift`.

Record precisely: the `cancelledSources` set, when an entry is added, when it is removed, that `addTask` clears the source while `queueChildTask` still honours it, and that `CancellationState` holds the per-task atomic flag that `host.isCancelled` reads lock-free from inside a running task. Confirm the Android and iOS implementations agree method for method, and note any place they do not.

### Step 6: Inventory the dev-server and web backends

Read and record `apps/dev-server/src/lib/worker-pool-inline.ts` and `apps/dev-frontend/src/lib/websocket-queue-backend.ts`. For the inline pool, record that tasks run in-process and how `cancelled` is set on the running-task record. For the WebSocket backend, record the `isCancelled: () => false` at line ~189 verbatim, and establish by reading the surrounding code whether a running task on this path can observe cancellation at all. This is a candidate divergence, so the finding must be evidence-based, not inferred.

### Step 7: Build the comparison matrix

From the notes, assemble a matrix with one row per backend (Bun CLI, Electron main, Electron renderer proxy, mobile embedded engine, dev-server inline, dev-frontend WebSocket) and columns for: where handlers run, how many run concurrently, how a task is dispatched, what `cancelTasks` does to running tasks, what it does to pending tasks, whether the source is remembered afterwards, how `isCancelled` is delivered, and what happens to child tasks. Any cell that cannot be filled from an actual line of code is marked unknown rather than guessed.

### Step 8: Write the document skeleton

Create `docs/task-queue-architecture.md` with this structure and no content yet beyond headings:

- Overview, and what this document does not cover (pointing at `docs/background-tasks.md`)
- The shared model: `IQueueBackend`, `TaskQueue`, sources, task lifecycle
- Backend by backend: one section each for the six backends
- Cancellation across platforms
- Known divergences
- Key files

### Step 9: Write the shared-model and per-backend sections

Fill sections from the step 2 to 6 notes. Every claim names the file it comes from. Each per-backend section answers the same four questions in the same order, so the sections can be read side by side: where does the handler run, how does a task get there, how does a result get back, what does cancelling do.

### Step 10: Add the diagrams

Add Mermaid diagrams, fenced as ```mermaid, following the existing usage in `docs/dependencies.md`:

1. **Component diagram** — `TaskQueue` above `IQueueBackend`, with the six implementations below it, and the process or device boundary each one crosses.
2. **Sequence diagram, CLI/Electron** — caller, `TaskQueue`, pool, worker: `addTask` through dispatch, handler execution, completion callback.
3. **Sequence diagram, mobile** — WebView `TaskQueue`, `EmbeddedJsQueueBackend`, the Capacitor plugin, `EnginePool`, `TaskEngine`, and the embedded engine, showing the `taskCompleted` event returning across the bridge.
4. **State diagram, task lifecycle** — pending, running, succeeded, failed, cancelled, and dropped-while-pending, with the transition labels used by the code.
5. **Sequence diagram, cancellation on mobile** — `shutdown()` on a `TaskQueue`, through `cancelTasks`, to the `cancelledSources` set and the per-task atomic flag, showing both the running-task path (polls `isCancelled`) and the pending-task path (dropped before dispatch).

Each diagram gets a sentence above it saying what to look at; a diagram with no prose is not finished.

### Step 11: Write the "Known divergences" section

Record each real difference found, with file and line, and a plain statement of the consequence. At minimum this must cover the `isCancelled: () => false` on the WebSocket backend if step 6 confirms it, and the fact that the mobile pool alone keeps a `cancelledSources` set at all, which is why the permanent-cancellation bug could only happen there. Do not propose fixes in this document beyond one sentence naming what would need to change.

### Step 12: Cross-link and verify

- Add a link to `docs/task-queue-architecture.md` from the guides list in `CLAUDE.md` and from `docs/development.md`.
- Add a line near the top of `docs/background-tasks.md` pointing at the new document for the cross-platform scheduling and cancellation detail, and a line in the new document pointing back for how to add a task type.
- Confirm every file path named in the document exists, by resolving each one.
- Confirm every Mermaid block parses, by publishing the document as an artifact and viewing it, or by rendering it in the stories browser if that is available; a diagram that does not render is a failed step.

## Unit Tests

This plan adds no functions, so it adds no unit tests. The existing unit tests in `packages/task-queue/src/test/` are read during step 2 as evidence of intended behaviour and are not modified.

If step 6 or step 11 turns up a divergence that is a genuine defect rather than a deliberate difference, do not fix it inside this plan. Record it in "Known divergences" and write a separate plan for the fix, which will carry its own unit tests.

## Smoke Tests

No new smoke tests. This plan changes documentation only, so the existing suites are the regression check that nothing was touched by accident:

- `bun run test:all` (unit, CLI, Electron) must be unchanged from before the work.
- `bun run test:and` must be unchanged: 38 of 39, with `34-s3-database` the only failure, until the hand-written S3 client is removed.

## Verify

- `bun run compile` is clean.
- `bun run test` passes.
- `bun run test:all` passes.
- `bun run test:and` shows the same result as before this work: only `34-s3-database` failing.
- `git status` shows changes only to `docs/task-queue-architecture.md`, `docs/background-tasks.md`, `docs/development.md` and `CLAUDE.md`. Any change to a source file means the plan was exceeded and must be reverted.
- Every file path named in `docs/task-queue-architecture.md` resolves to a file that exists.
- Every Mermaid block in the document renders.
- The document has a section for each of the six backends and a filled comparison matrix with no unknown cells, or an explicit statement of why a cell could not be determined.

## Notes

- The document describes what the code does today, not what it should do. Where the code is wrong, that goes in "Known divergences" with a file and line, and the fix is separate work.
- `docs/background-tasks.md` already covers adding a task type, the host bridge and the NOT IMPLEMENTED rule. Duplicating any of it is a defect in this plan's output; link instead.
- Findings must come from reading code, not from this conversation or from existing prose. Two of the behaviours that matter most here (mobile remembering a cancelled source, the WebSocket backend's constant-false `isCancelled`) were both invisible in the documentation that existed at the time.
- The mobile `cancelledSources` behaviour was changed recently in `EnginePool.java` and `EnginePool.swift`: `addTask` now clears the source while `queueChildTask` still honours it. Read the current code rather than relying on any earlier description.
- Six backends is itself the finding worth surfacing. If the inventory shows some of them are near-duplicates that could be collapsed, note it in "Known divergences" as an observation, and leave the decision to a later plan.
