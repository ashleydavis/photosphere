# Job Manager

## Managed Background Jobs

The following background activities will be surfaced through the Job Manager:

- **Import Assets** — the import worker tasks carry job metadata; cancellable. Progress is reported as *"N of M files"* as the worker processes each asset.
- **Load Assets** — the load-assets worker tasks carry job metadata; cancellable. Progress is reported as *"N assets loaded"* (indeterminate unless the merkle tree provides a total).
- **Replicate Database** — the replicate worker tasks carry job metadata; cancellable. Progress is reported as the per-file status string emitted by the replicate worker. The dialog becomes dismissable mid-task via a *Run in background* button.
- **Sync Database** — the sync worker tasks carry job metadata; not cancellable in v1. Progress is indeterminate.
- **Verify Database** (future) — to be registered when the Verify flow is implemented, following the same pattern (see the Notes section).

## Overview

Today the app surfaces background work in scattered, ad-hoc ways: the Import context owns the import session, `AssetDatabaseSource` owns the load-assets queue, the Replicate dialog locks itself open until completion, and sync runs silently. There is no app-level concept of "a piece of background work the user can see and cancel". This plan introduces a centralised **Job Manager**.

The source of truth for job state lives in the **backend**: the process that owns the real worker pool (Electron main, the CLI process, the dev-server, the mobile embedded-JS-engine host) — the same place `setQueueBackend(realPool)` is called. That is where tasks actually start, stream progress, complete, and cancel, so that is where jobs are derived and owned. A `JobRegistry` there aggregates tasks by their `source` into jobs, and **automatically**: registers a job when the first task of a source starts, updates it from worker progress messages, and completes it when the last task of that source finishes. Every change is pushed to the frontend as a job event over the existing platform push transport.

The frontend keeps a thin **jobs context** that is a pure mirror of what the backend broadcasts. `main.tsx` subscribes to job events and applies them to the context. Two UI surfaces read the context: a compact indicator in the right of the navbar (single job name + spinner, or *"N jobs running"* when multiple) and a list in the right sidebar (per-job progress + Cancel). Cancel routes through the existing `platform.cancelTasks(sourceTag)`.

The flows (Import, Load Assets, Replicate, Sync) do **not** call any register/update/complete methods. They only attach a job descriptor (name + cancellable) to the tasks they already queue; the backend does the rest. This is the core difference from the previous design (see Issues).

## Terminology
- **Task**: a single unit of work with a `type` (for example `hash-file`, `load-assets`, `import-assets`) and input `data`, dispatched through the task queue and run by a registered handler. A task returns a result, can stream progress messages, can be cancelled, and is tagged with a `source` string that groups related tasks. Defined in `packages/task-queue`.
- **Background task**: a task, emphasising that it runs off the UI/main thread in a worker. In this codebase every task is a background task; the terms are used interchangeably for the worker-level unit of work.
- **Task queue** (`TaskQueue` / `IQueueBackend`, `packages/task-queue`): the mechanism that accepts tasks (`addTask`), dispatches them to a backend, and returns results and streamed messages (`awaitTask`, `onTaskComplete`, `onTaskMessage`). `TaskQueue` is the caller-facing API; `IQueueBackend` is the pluggable executor/transport behind it. The **real** backend (the worker pool) runs in the host process; a **proxy** backend (IPC/WebSocket/host-bridge) runs in the frontend and forwards to it.
- **Worker pool**: an `IQueueBackend` implementation that owns a set of workers and runs task handlers across them in parallel (for example `WorkerPoolBun` on CLI, `WorkerPoolElectronMain` on desktop). This is "the backend" that owns job state.
- **Background job** (`IJob`): a user-visible background activity shown in the navbar indicator and sidebar list with a name, progress, and optional Cancel. A job maps 1:1 to a task `source`: it is the aggregate of all in-flight tasks sharing that source. Cancelling a job cancels those tasks via `platform.cancelTasks(source)`.
- **Job event**: a message pushed from the backend to the frontend describing a job upsert (register/update) or completion. The frontend applies these to the jobs context; it never mutates job state itself.

## Architecture

Event flow (Electron shown; mobile/CLI/dev-server are analogous, differing only in transport):

```
flow (frontend)                 backend host (main process)              frontend
  queue.addTask(type, data,       WorkerPoolElectronMain
    { job: { name, cancellable }})   -> JobRegistry.onTaskAdded(source, jobInfo)
        |  add-task IPC  ------------>       creates job for source (first task)
        |                                    emits job-event {kind:"upsert", job}
        |                             <------ webContents.send('platform-event',
        |                                       { type:"job-event", ... })
        |                                                                  main.tsx onJobEvent
        |                                                                    -> jobs context upsert
  worker emits {type:"job-update",  JobRegistry.onAnyTaskMessage
    progress, progressMessage}  --->   applies to job, emits job-event upsert  -> context update
  last task of source completes    JobRegistry.onTaskComplete
                                     in-flight count for source hits 0
                                     emits job-event {kind:"complete", id}      -> context remove
  Cancel button -> platform.cancelTasks(source)  ->  pool cancels tasks -> registry completes job
```

Where each piece lives:

- **`JobRegistry`**: new class in `packages/task-queue`. Constructed in each host that owns a real pool, given the pool and a `sendJobEvent` callback. Holds the authoritative job map.
- **Job event transport**: the existing generic push channel per platform. Electron reuses `platform-event` (no new action-specific IPC channel, per the CLAUDE.md rule); mobile uses the host bridge; dev-server uses the WebSocket. A new `platform.onJobEvent(cb)` hook on `IPlatform` exposes the stream to the frontend uniformly.
- **`JobsContextProvider`**: unchanged shape, but its state is driven only by applied job events. `cancelJob(id)` still calls `platform.cancelTasks(job.sourceTag)`.
- **`main.tsx`**: subscribes to `platform.onJobEvent` and applies upserts/completions to the context.

## Steps

### 1. Define the job model and job-event types

**File:** `packages/task-queue/src/lib/types.ts` (shared so backend and frontend agree).

Define and export:

- `IJobInfo` — the descriptor a flow attaches to its tasks:
  - `name: string` — human-readable label, e.g. *"Importing 124 photos"*.
  - `cancellable: boolean` — whether the Cancel button is rendered.
- `IJob` — the full job as broadcast to the frontend:
  - `id: string` — equals the task `source`; stable React key.
  - `sourceTag: string` — value passed to `platform.cancelTasks(sourceTag)`; equals `id` in v1 but kept separate for flexibility.
  - `name: string`, `cancellable: boolean` — from `IJobInfo`, `name` refinable via `job-update`.
  - `progress: number | undefined` — fractional `0..1`, undefined means indeterminate.
  - `progressMessage: string | undefined` — short detail (e.g. *"Copying display.jpg"*).
  - `startedAt: number` — timestamp at registration; used to sort the sidebar list.
- `IJobUpdateMessage` — the task-message payload a worker emits to update its job: `{ type: "job-update"; name?: string; progress?: number; progressMessage?: string }`.
- `IJobEvent` — pushed backend→frontend: a discriminated union of `{ kind: "upsert"; job: IJob }` and `{ kind: "complete"; id: string }`.

### 2. Attach job metadata to tasks

The mechanism that makes registration automatic: a flow declares job info once for its `source`, and the backend derives the job from it.

**File:** `packages/task-queue/src/lib/queue-backend.ts` and `task-queue.ts`.

- Extend `IQueueBackend.addTask` and `TaskQueue.addTask` with an optional trailing `jobInfo?: IJobInfo`. When present, it is forwarded to the real backend in the add-task payload.
- The `JobRegistry` uses the first non-undefined `jobInfo` seen for a `source` to create the job. Tasks added for a source that already has a job ignore their `jobInfo` (the job already exists). Tasks with no `jobInfo` (e.g. internal `hash-file` children) never create a visible job on their own.
- Forward `jobInfo` through the proxy backends: `ElectronRendererQueueBackend` (in the `add-task` IPC payload), `WorkerQueueBackend` (in the `queue-task` message), `WebSocketQueueBackend`, and the mobile `EmbeddedJsQueueBackend`.

### 3. The JobRegistry (backend source of truth)

**File:** `packages/task-queue/src/lib/job-registry.ts` (new).

- `JobRegistry` constructor takes the real `IQueueBackend` (the pool) and a `sendJobEvent: (event: IJobEvent) => void` callback.
- Internal state: `Map<string, IJob>` keyed by `source`, plus a `Map<string, number>` of in-flight task counts per source.
- Wire to the pool:
  - On a task added with a `source` and `jobInfo`: increment the source's in-flight count. If the source has no job yet, create `IJob` from `jobInfo` (progress/message undefined, `startedAt` from the timestamp provider) and `sendJobEvent({ kind: "upsert", job })`. This requires a global task-added observation on the real pool. Add a small `onAnyTaskAdded(cb: (taskId, source, jobInfo) => void)` to the real pools (`WorkerPoolBun`, `WorkerPoolElectronMain`, `WorkerPoolInline`, mobile runtime); the registry is the only consumer.
  - On `onAnyTaskMessage`, if the message is `IJobUpdateMessage`, merge `name`/`progress`/`progressMessage` into the source's job and emit an `upsert`.
  - On `onTaskComplete`, decrement the source's in-flight count. When it reaches zero, delete the job and `sendJobEvent({ kind: "complete", id: source })`.
  - On `onTasksCancelled(source)` (cancellation), drop the job immediately and emit `complete` so the row disappears without waiting for the tasks to settle.
- **Completion must be idempotent.** Both natural completion and `onTasksCancelled` can fire for the same source (e.g. the `replicateDatabase` wrapper calls `shutdown()` → `cancelTasks(source)` right after the task already completed). Completing an already-removed source must be a silent no-op: only emit `complete` if the job still exists, and clear the in-flight count for that source.
- Unit-testable in isolation with a fake backend and a captured `sendJobEvent`.

### 4. Construct the registry in each host and forward job events

Each host that calls `setQueueBackend(realPool)` also constructs a `JobRegistry(realPool, sendJobEvent)` where `sendJobEvent` uses that host's push transport.

- **Electron:** `apps/desktop/src/main.ts` `initWorkers()`. `sendJobEvent` = `mainWindow?.webContents.send('platform-event', { type: "job-event", event })`. Reuse the existing `platform-event` channel; do not add a new IPC channel.
- **Mobile:** the embedded-JS-engine host (`packages/mobile-worker/src/lib/mobile-worker-runtime.ts` and the native bridge). `sendJobEvent` posts a job event over the host bridge alongside task messages; `PlatformProviderMobile` surfaces it (see Step 5).
- **Dev-server / web:** `apps/dev-server`. `sendJobEvent` broadcasts a job event over the WebSocket; `WebSocketQueueBackend` / `platform-provider-web` receive it.
- **CLI:** `apps/cli`. No frontend, so `sendJobEvent` is a no-op (or logs). The registry still runs harmlessly.

### 5. Expose job events to the frontend uniformly

**File:** `packages/user-interface/src/context/platform-context.tsx` and each platform provider.

- Add `onJobEvent(callback: (event: IJobEvent) => Unsubscribe)` to `IPlatform`, alongside `onSyncStarted`/`onSyncCompleted`.
- Implement it in each provider by subscribing to that platform's job-event push:
  - `platform-provider-electron.tsx`: filter `platform-event` messages of `type === "job-event"`.
  - `platform-provider-mobile.tsx`: subscribe to the host-bridge job-event stream.
  - `platform-provider-web.tsx`: subscribe to the WebSocket job-event stream.
  - stories/mock provider: a no-op or a stub that lets stories push fake job events.

### 6. Jobs context (mirror only)

**File:** `packages/user-interface/src/context/jobs-context.tsx` (new).

Keep the good shape, but strip the lifecycle-owning methods:

- `IJob` re-exported from `task-queue` types (single definition).
- `IJobsContext`:
  - `jobs: IJob[]` — current jobs, sorted by `startedAt`.
  - `applyJobEvent(event: IJobEvent): void` — upsert or remove; the *only* mutator, called by `main.tsx`. Not intended for flows.
  - `cancelJob(id: string): void` — looks up the job, calls `platform.cancelTasks(job.sourceTag)`. Does not remove the row; the backend will emit `complete` in response to cancellation (Step 3). This keeps the frontend from guessing.
- `JobsContextProvider({ children })` — holds the `jobs` array, provides `applyJobEvent` and `cancelJob`, reads `platform` via `usePlatform()`.
- `useJobs(): IJobsContext` with the standard "throw if no provider" guard.
- Removed vs. the previous design: `registerJob`, `updateJob`, `completeJob`. Flows no longer touch the context.

Extract the array-apply logic (`applyJobEvent` upsert/remove/sort) into a plain function under `lib/` (e.g. `apply-job-event.ts`) and unit-test that; keep the provider a thin shell.

### 7. Mount the provider and wire the subscription in main.tsx

**File:** `packages/user-interface/src/main.tsx`.

- Wrap the tree in `<JobsContextProvider>` (inside `PlatformContextProvider`, outside `AssetDatabaseProvider` and the gallery/import contexts).
- Add a `useEffect` that subscribes to `platform.onJobEvent` and calls `applyJobEvent(event)`. Clean up on unmount. This is the single frontend entry point for job state.
- Add the `photosphere:show-jobs` window-event listener that opens the right sidebar (see Step 9).

### 8. Navbar job indicator

**File:** `packages/user-interface/src/components/navbar-jobs-indicator.tsx` (new) and `navbar.tsx`.

- Reads `useJobs()`. Render rules:
  - `jobs.length === 0`: render `null`.
  - `jobs.length === 1`: `<CircularProgress size="sm" />` (determinate when `progress !== undefined`) + the job's `name`, with a small grey percentage when `progress` is numeric.
  - `jobs.length > 1`: `<CircularProgress size="sm" />` + *"N background jobs running"*, aggregate progress = mean of numeric `progress` values (indeterminate jobs ignored).
- Clicking dispatches `photosphere:show-jobs`. `data-id="navbar-jobs-indicator"`.
- Mount in the navbar's right cluster before the existing right-side controls.

### 9. Right sidebar jobs list

**File:** `packages/user-interface/src/components/sidebar-jobs-list.tsx` (new) and `right-sidebar.tsx`.

- Reads `useJobs()`. `jobs.length === 0` renders `null`.
- Otherwise a `<Typography level="title-sm">Background jobs</Typography>` header, then one row per job with: `name`, `progressMessage` in small grey text when present, a determinate `<LinearProgress determinate value={progress*100} />` (or indeterminate when `progress` is undefined), and — when `cancellable` — an icon-only cancel `<IconButton size="sm" variant="plain" color="danger" aria-label="Cancel job" title="Cancel">` (Font Awesome `fa-xmark`/`fa-circle-xmark`, matching the existing icon mechanism) calling `cancelJob(job.id)`.
- `data-id`: `sidebar-jobs-list`, `sidebar-job-row-{job.id}`, `sidebar-job-cancel-{job.id}`.
- Mount as the first section in the right sidebar with `Divider` spacing.

### 10. Flows: attach job metadata only

No flow calls register/update/complete. Each flow attaches `jobInfo` to the tasks it queues, and (where progress is known) its worker emits `job-update` messages.

- **Import** (`packages/user-interface/src/context/import-context.tsx`): pass `{ name: "Importing assets", cancellable: true }` as `jobInfo` on the existing `queue.addTask("import-assets", ...)` call (source = `sessionId`). The import worker should emit `{ type: "job-update", progress, progressMessage: \`${processed} of ${total} files\`, name: \`Importing ${total} files\` }` as it processes assets. **Note (new work):** today the import worker emits only per-asset messages (`import-success`/`import-skipped`/`import-failed`/`scan-progress`) and no running total — the reverted design computed `processed`/`total` in the frontend from its own `importItems` array. To keep progress backend-driven, the worker must maintain its own processed/total counters (total known after the scan phase) and emit `job-update`. This is the one non-trivial worker addition in this plan.
- **Load Assets** (`packages/user-interface/src/context/asset-database-source.tsx`): pass `{ name: \`Loading database "${name}"\`, cancellable: true }` as `jobInfo` when queueing `load-assets` (source = `dbPath`). The load-assets worker emits `job-update` with `progressMessage: \`${count} assets loaded\`` (and `progress` if a total is known). No total is known up front, so it stays indeterminate.
- **Replicate**: replicate does not queue its own task inline — the frontend and CLI both go through the shared wrapper `replicateDatabase(uuidGenerator, data, onProgress)` in `packages/node-api/src/lib/replicate-database.ts`, which does the `TaskQueue` dance (`addTask("replicate-database", data)`, `awaitTask`, then `shutdown()`). Attach `{ name: \`Replicating to ${destPath}\`, cancellable: true }` as `jobInfo` on that wrapper's `addTask`. The replicate worker emits `job-update` from its existing progress callback. In `replicate-database-dialog.tsx`, make the dialog dismissable (`<Modal onClose={onClose}>`) with a *Run in background* button (`data-id="replicate-run-in-background-button"`) that just calls `onClose`; it no longer owns running state. **Gotcha:** `replicateDatabase` calls `queue.shutdown()` after completion, and `shutdown()` calls `backend.cancelTasks(source)`. So the registry sees a `cancelTasks` for the source even on a successful run, right after the task already completed. Job completion must therefore be idempotent (see Step 3) so the trailing cancel does not double-fire or error.
- **Sync**: sync is **queued in the backend, not from a frontend flow** — `apps/desktop/src/main.ts` (`workerPool.addTask("sync-database", ...)`), `apps/dev-server/src/index.ts`, and the mobile host. Attach `{ name: \`Syncing database "${name}"\`, cancellable: false }` as `jobInfo` at those backend call sites. Sync therefore needs **zero** frontend flow changes: no `onSyncStarted`/`onSyncCompleted` bookkeeping, no `syncJobIdRef`, no stale-path ref. Sync progress stays indeterminate in v1.

### 11. Replicate worker: honour cancellation

**File:** `packages/node-api/src/lib/replicate.ts` (and its worker).

- The replicate loops must early-out when cancelled so the Cancel button actually interrupts an in-flight copy. Add `context.isCancelled()` checks at the per-file and per-merkle-node loop boundaries; on cancel, stop cleanly and let the worker surface `TaskStatus.Failed`. (This is the only worker-side cancellation change: import and load-assets workers already early-out; sync is non-cancellable in v1.)

### 12. Docs

- **File:** `CLAUDE.md`. Update the Job Manager rule to reflect the new contract:

  > User-visible background activities register as jobs *automatically*: attach an `IJobInfo` (`name`, `cancellable`) to the tasks you queue for a `source`, and emit `job-update` task messages for progress. The backend `JobRegistry` (in the process that owns the worker pool) owns job state and pushes job events to the frontend; the jobs context is a read-only mirror. Do not call register/update/complete from the frontend, and do not create flow-specific progress UI — rely on the shared navbar indicator and sidebar list.

- **File:** `docs/background-tasks.md`. Add a short section: "Surfacing a task as a job" describing `jobInfo` + `job-update`.

## Unit Tests

- **`job-registry.test.ts`** (new, `packages/task-queue`): drive a fake backend; assert
  - first task with `jobInfo` for a source emits an `upsert`; subsequent tasks for the same source do not re-create it but bump the in-flight count;
  - a `job-update` message merges `name`/`progress`/`progressMessage` and emits an `upsert`;
  - the job completes (emits `complete`) only when the *last* in-flight task for the source finishes, not the first;
  - cancellation for a source emits `complete` immediately.
- **`apply-job-event.test.ts`** (new, `packages/user-interface`): the plain array-apply function; assert upsert adds/replaces by id, `complete` removes by id, ordering by `startedAt`, no-op on completing an unknown id.
- **`navbar-jobs-indicator.test.tsx`** — do not unit test the component. Extract the aggregate-progress calculation into a `lib/` function and test that (mean of numeric progress, ignore indeterminate).
- **`sidebar-jobs-list`** — same rule: any non-trivial logic goes into a `lib/` function with tests; the component stays a thin shell.
- Extend the queue-backend / proxy-backend tests so `jobInfo` is forwarded through each transport.

## Smoke Tests

The Job Manager is plumbing for existing flows; the way to know it has not regressed any flow is that each flow's existing smoke test still passes end-to-end after the refactor.

- **Load Assets** — [3-open-database](apps/desktop/smoke-tests/3-open-database/), [10-view-database](apps/desktop/smoke-tests/10-view-database/). No edits expected.
- **Import Assets** — [4-import-photos](apps/desktop/smoke-tests/4-import-photos/). No edits expected.
- **Replicate Database** — [17-replicate-database](apps/desktop/smoke-tests/17-replicate-database/). Required edit: the *Running* actions now expose `data-id="replicate-run-in-background-button"` instead of being blocked-open. Update the wait logic; remove any assertion that the dialog cannot be closed mid-task.
- **Sync Database** — no dedicated smoke test; existing tests that incidentally trigger a sync continue unchanged.

Verification rule: after the refactor, `bun run test:electron` must pass with no edits beyond the single `17-replicate-database` update.

## Verify

1. `bun run compile` from repo root — clean.
2. `bun run test:all` from repo root — full unit and smoke suites green, including the new `job-registry` / `apply-job-event` unit tests and the updated `17-replicate-database` smoke test.
3. `bun run stories:and` — confirm the navbar indicator and sidebar list fit at phone resolution.

## Notes

- **Why backend-owned job state?** The backend already sees every task start, message, completion, and cancellation for every source. Deriving jobs there makes registration and completion automatic and impossible to forget, removes per-flow bookkeeping, and keeps the frontend a pure renderer. This is the central change from the reverted design (see Issues 1-4).
- **Why one job per `source`?** `source` already groups related tasks and is already the cancellation key. A job is exactly "the in-flight tasks for a source", so the mapping is free and cancellation routes through the existing `platform.cancelTasks(source)`.
- **Why reuse `platform-event` on Electron?** The CLAUDE.md rule forbids new action-specific IPC channels. Job events ride the existing generic push channel as `{ type: "job-event", ... }`.
- **Cancel does not optimistically remove the row.** `cancelJob` calls `platform.cancelTasks` and waits for the backend's `complete` event. The backend is the source of truth, so the row disappears when the backend says the job is gone, avoiding divergence.
- **Progress lives with the worker.** Progress strings/fractions are computed by the worker (which knows the real counts) and emitted as `job-update` messages, not recomputed in the frontend. This keeps job data flowing from the one place that has it.
- **Replicate cancellation is the only worker-side code change.** Import and load-assets already honour `context.isCancelled()`. Sync is non-cancellable in v1. Verify (future) will need the same care.
- **Mobile requirement.** `PlatformProviderMobile` must wire `cancelTasks` and the task/job callbacks to the `JsEngine` plugin (no-op stubs today), and the mobile host must construct a `JobRegistry` and forward job events over the host bridge, or Cancel does nothing and jobs never appear on mobile. This depends on the mobile-background-tasks work.
- **Future (Verify).** When Verify Database is implemented, attach `{ name: \`Verifying "${db}"\`, cancellable: true }` to its tasks (source = database path) and have its worker emit `job-update` and honour cancellation like replicate. No Job Manager changes required.
- **What this plan does not change.** The `platform.cancelTasks` IPC contract, the `TaskQueue` public API (beyond the optional `jobInfo` arg), the toast system, and the sync trigger logic (debounce/timer) are unchanged.

## Implementation notes from the reverted attempt

Salvaged from the `job-manager` worktree before it was reverted. These speed up a re-implementation; they are observations, not new requirements.

**Reuse these (they were already right):**

- The reverted `jobs-context.tsx` had already factored all logic into plain exported functions with non-rendering unit tests: `registerJobInList`, `updateJobInList`, `removeJobFromList`, `aggregateJobsProgress`, `describeJobsIndicator`, `describeJobRow`, plus the view interfaces `IJobsIndicatorView` and `IJobRowView`. These map cleanly onto the new design: `describeJobsIndicator`/`aggregateJobsProgress` become the navbar indicator's `lib/` logic, `describeJobRow` becomes the sidebar row's, and `registerJobInList`/`removeJobFromList` become the `applyJobEvent` upsert/remove helpers. Copy them across; do not re-derive.
- The tests lived under `src/test/components/` but only imported and tested the extracted functions (no React rendering), which satisfies the "no component tests" rule. Keep that arrangement.
- The provider mirrored `jobs` into a `jobsRef` so `cancelJob` could be a stable `useCallback` that reads the current list without depending on it. Keep this pattern for `cancelJob`.

**Change these (they are what the Issues call out):**

- The reverted `cancelJobInList` optimistically removed the row locally and swallowed cancel errors. In the new design `cancelJob` only calls `platform.cancelTasks(sourceTag)` and lets the backend's `complete` event remove the row. Do not remove locally.
- `registerJob`/`updateJob`/`completeJob` were public context methods called by flows. They are gone; only `applyJobEvent` (driven by `main.tsx`) and `cancelJob` remain.

**Gotchas that will bite the re-implementation:**

- `onTaskAdded` and `onTasksCancelled` fire *locally in the frontend proxy backends* (`ElectronRendererQueueBackend`, `WorkerQueueBackend`), not from the real pool. So the renderer-side `TaskQueue` in-flight counting is renderer-local and is not a source of truth. The `JobRegistry` must observe the **real** pool. The real pools expose `onTaskComplete` and `onAnyTaskMessage` globally, but `onTaskAdded(source, cb)` is **per-source** — there is no global "any task added" hook today. Adding `onAnyTaskAdded(cb)` to the real pools (Step 3) is the key enabling change; without it the registry cannot learn of new sources.
- `platform.cancelTasks(source)` returns `Promise<void>` (it is async); handle rejection where you call it.
- Frontend integration surface touched by the reverted attempt (expect to touch the same files): `main.tsx` (mount + the single subscription), `index.tsx` (re-exports), `stories/mocks/index.tsx` (the mock platform needs an `onJobEvent` stub so stories can push fake job events), and each `app.tsx` (`apps/desktop-frontend`, `apps/dev-frontend`, mobile) where the platform provider is assembled.
- The reverted replicate cancellation added a `throwIfCancelled(isCancelled)` helper called at three loop boundaries in `packages/node-api/src/lib/replicate.ts` (per-file copy loop and per-merkle-node loops), with the worker passing `() => context.isCancelled()`. That approach is sound; keep it (Step 11).

**Design-relevant discoveries (now folded into the Steps, flagged here so they are not missed):**

- Sync is queued in the **backend** (`apps/desktop/src/main.ts`, `apps/dev-server/src/index.ts`, mobile host), not from a frontend flow, so its `jobInfo` attaches there and sync needs no frontend changes at all (Step 10, Sync).
- Replicate is queued through the shared `replicateDatabase()` wrapper in `packages/node-api/src/lib/replicate-database.ts`, which calls `shutdown()` → `cancelTasks(source)` after completion — hence the idempotent-completion requirement (Step 3, Step 10 Replicate).
- Import's numeric progress was computed in the frontend from its own `importItems` array; the import worker emits no running total today, so making progress backend-driven needs new counter/`job-update` logic in the worker (Step 10, Import). This is the only non-trivial worker addition.
