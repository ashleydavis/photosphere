# Job Manager

## What a job is

A **job** is a named group of tasks. Whatever queues a task decides which job it belongs to and puts a **job tag** in the task's input data. The task's handler echoes that tag back in the progress messages it already sends. The interface collects those messages, shows one row per job with its name, how long it has been running and what it is doing, and drops the row when the last task carrying that job's id has completed. Cancel stops the job's tasks.

Jobs exist **only in the frontend**. Nothing in the backend or the workers keeps job state, counts jobs, or decides when a job is over. The only thing added to a task is that it knows which job it belongs to.

## Managed jobs

- **Importing photos**: the manual import. One `import-assets` task per import session. Cancellable.
- **Loading assets**: one `load-assets` task per database open. Cancellable.
- **Replicating to X**: one `replicate-database` task. Cancellable. The dialog gains a *Run in background* button, after which the sidebar row is where the replication is watched and cancelled from.
- **Syncing database**: one or more `sync-database` tasks per sync pass (mobile runs a pass as a list of steps). Not cancellable: see "Why sync has no Cancel" below.
- **Automatic import** gets no job tag and so is not a job. It runs for as long as the setting is on, so a row that never goes away would say nothing that the setting does not already say, and the Import page's own progress panel already shows what it is doing.
- **Verify Database** (future) will be a job by doing what the four above do; no Job Manager changes needed.

## Overview

Today the app surfaces background work in scattered, ad-hoc ways: the Import context owns the import session, `AssetDatabaseSource` owns the load-assets queue, the Replicate dialog locks itself open until completion, and sync shows one word in the navbar. There is no app-level place that says "here is the background work running, here is how long it has been going, stop it".

This plan adds one. A navbar indicator says how many jobs are running and names the one job when there is only one. The right sidebar lists them, each with its elapsed time, a progress bar, what it is currently doing, and a Cancel button where the job can be cancelled.

## How the interface finds out

Two streams already reach every frontend from the process that owns the worker pool, on every platform, for **every** task regardless of who queued it:

- `platform.onTaskMessage(taskId, message)`
- `platform.onTaskComplete(taskId, result)`

Desktop's main process forwards both to the renderer for every task (`initWorkers` in `apps/desktop/src/main.ts`). The mobile `JsEnginePlugin` emits both to the WebView for every task, buffering them until a listener registers. This is proven in code that runs today: `platform-provider-mobile.tsx` already reacts to `sync-started` messages and to `sync-database` completions, and those tasks are queued by the **native** `SyncDriver`, never by the WebView.

So the interface needs no new event, no new IPC channel, no new native plugin event, no change to `addTask`, no change to any worker pool, and no change to `IQueueBackend` or `ITaskQueue`. It needs the job tag to be in the messages, which is the handler echoing what its own input data told it.

```
whoever queues the task           worker handler                    frontend
  data: { ..., job: {              sendJobProgress(context,
      id, name, cancelSource } }  ---> context.sendMessage(
                                         { type: "job-progress",
                                           job, startedAt,
                                           progress,
                                           progressMessage })
                                                  |
                                    task-message  |  (already forwarded
                                                  v   for every task)
                                                       platform.onTaskMessage
                                                         -> job row appears / updates
                                                         -> this taskId counted into the job

  handler returns or throws  ---> task-completed ---->   platform.onTaskComplete
                                                         -> taskId dropped from the job
                                                         -> job row removed when none are left

  Cancel button  ---------------------------------->  platform.cancelTasks(job.cancelSource)
                                                         -> task fails -> row removed
```

## Why the job tag travels in the task's data

The alternative is a first-class `job` argument on `addTask`, stored on `ITask` and echoed into the payloads the pool pushes out. That was rejected for one reason that is fatal and one that is merely expensive:

- **Mobile's pool is native.** The real pool on iOS and Android is `EnginePool.swift` and its Android counterpart. For a `job` field on the task record to reach the WebView, the native pools would have to store it and put it in their `taskMessage` / `taskCompleted` payloads: Swift and Kotlin changes, with their own tests, before a single job appears on a phone. Putting the tag in the task's `data` needs none of that, because `data` is an opaque JSON string to the native side and is built in TypeScript at both ends.
- **Sync and automatic import are queued by the host, not the frontend.** Desktop queues `sync-database` in `main.ts`; mobile queues its sync steps from `SyncDriver` via `runBackgroundTask`. Neither goes through the frontend's `addTask`, so a frontend that only knew about jobs it queued itself would never see a sync. It has to learn from the message stream either way, and once it does, a first-class field buys nothing.

The cost of the data route is that four task-data interfaces gain an optional `job` field and four handlers call one shared helper. That is the whole footprint in the backend.

## Why sync has no Cancel

Cancelling means calling `platform.cancelTasks(source)`, and the source a sync task was queued under is decided by the host: `currentDatabasePath` on desktop, a native constant (`backgroundSyncTaskSource`) on mobile. The `plan-sync` task that builds the mobile sync steps does not know that constant, so it cannot put a truthful `cancelSource` in the tag. Rather than guess one, sync leaves `cancelSource` out, which is how the tag says "this job cannot be cancelled from here" and the row renders without a Cancel button. Syncing is switched off from Settings, which is where a user looks for it.

## Steps

### 1. The job tag and the job-progress message

**File:** `packages/task-queue/src/lib/types.ts`.

```ts
//
// Names the user-visible job a task belongs to. Whatever queues the task puts this in the task's
// input data, and the task's handler echoes it back in the progress it reports, which is how the
// interface finds out about work it did not queue itself.
//
export interface IJobTag {
    //
    // Groups every task of this job. The interface shows one row per id, and drops the row when the
    // last task carrying this id has completed.
    //
    id: string;

    //
    // What the row is called, for example "Importing photos".
    //
    name: string;

    //
    // The task source to cancel to stop this job, which is what the Cancel button calls
    // platform.cancelTasks() with. Left out when the job cannot be cancelled from the interface:
    // a background sync is queued by the host under a source the interface never learns, so it
    // says so by leaving this out rather than by guessing at one.
    //
    cancelSource?: string;
}

//
// What a task handler reports about the job it is doing. Sent whenever its progress moves, and
// carrying the whole job every time, so an interface that was not listening when the job started
// (a mobile WebView the system had suspended) learns all of it from the next one.
//
export interface IJobProgressMessage {
    //
    // Discriminates this from every other task message.
    //
    type: "job-progress";

    //
    // The job this task belongs to, straight from the task's input data.
    //
    job: IJobTag;

    //
    // When the handler started work, in milliseconds since the epoch. The elapsed time the
    // interface shows counts from here rather than from when it first saw the job, so a job that
    // was already running when the app came back to the foreground reports its real age.
    //
    startedAt: number;

    //
    // How far along the job is, from 0 to 1. Left out when there is no total to be a fraction of,
    // which is every job in this plan: all four scan or stream and do not know their size up front.
    //
    progress?: number;

    //
    // What the job is doing right now, for example "12 imported, 3 already there".
    //
    progressMessage?: string;
}
```

**File:** `packages/task-queue/src/lib/job-progress.ts` (new). One helper so the four handlers do not repeat the message literal:

```ts
//
// Reports a job's progress from inside a task handler. Does nothing when the task carries no job
// tag, which is how a task nobody asked to see (an automatic import, an internal child task) stays
// out of the interface without its handler having to know that.
//
export function sendJobProgress(context: ITaskContext, job: IJobTag | undefined, startedAt: number, progress: number | undefined, progressMessage: string | undefined): void
```

Exported from `packages/task-queue/src/index.ts`.

### 2. Task data carries the tag

Add `job?: IJobTag` to the input data interface of each task that can be a job:

- `IImportAssetsData` (`packages/api/src/lib/import-assets.types.ts`)
- `ILoadAssetsData` (`packages/api/src/lib/load-assets.types.ts`)
- `IReplicateDatabaseData` (`packages/api/src/lib/replicate-database.types.ts`)
- the `sync-database` input data interface (`packages/api`, beside the other two)

### 3. Queue sites fill the tag in

Each site names its own job. The id is chosen so two of the same kind of job on different databases are two rows, not one.

| Site | Tag |
|---|---|
| `packages/user-interface/src/context/import-context.tsx`, `startImportWithPaths` | `{ id: sessionId, name: "Importing photos", cancelSource: sessionId }` |
| `packages/node-api/src/lib/import.ts` (the CLI's import) | the same, from the session id it already mints |
| `packages/api/src/lib/load-assets.ts` | `{ id: \`load:${databasePath}\`, name: "Loading assets", cancelSource: databasePath }` |
| `packages/node-api/src/lib/replicate-database.ts` | `{ id: \`replicate:${data.destPath}\`, name: \`Replicating to ${destName}\`, cancelSource: data.sourcePath }` |
| `apps/desktop/src/main.ts`, the sync `addTask` | `{ id: \`sync:${currentDatabasePath}\`, name: "Syncing database" }` |
| `apps/dev-server/src/index.ts`, the sync `addTask` | the same |
| `packages/mobile-worker/src/lib/plan-sync.worker.ts`, building each step's `dataJson` | the same, from the plan's `databasePath` |

The automatic-import `addTask` calls (`apps/desktop/src/main.ts` and the mobile auto-import planner) are deliberately left alone: no tag, no job.

The CLI has no job list to show, so it gains nothing visible from this. It sets the tag because `replicateDatabase` and `import.ts` are shared with the desktop, and a tag on a task the CLI runs costs a field in a JSON payload.

### 4. Handlers echo the tag

Each handler calls `sendJobProgress` from the point where it already reports progress, capturing `startedAt` once when it begins.

- **`import-assets.worker.ts`**: inside `sendImportProgress()`, which already runs on every file completion and on a timer, and already holds `runStartedAt` and the imported/skipped/failed counters. `progressMessage` is `${imported} imported, ${skipped} already there`, with `, ${failed} failed` appended when non-zero. Indeterminate: the scan streams, so there is no total until the run is over.
- **`load-assets.worker.ts`**: beside each `asset-page` message. `progressMessage` is `${count} assets loaded`. Indeterminate.
- **`replicate-database.worker.ts`**: beside each `replicate-progress` message, passing the same progress string through as `progressMessage`. Indeterminate.
- **`sync-database.worker.ts`**: immediately after the `sync-started` message, and again on completion of each batch it already reports. Indeterminate.

### 5. Job list logic

**File:** `packages/user-interface/src/lib/jobs.ts` (new). Plain exported functions, no React, no context.

```ts
// One row in the jobs list.
export interface IJob {
    id: string;                    // the job tag's id
    name: string;
    cancelSource: string | undefined;
    startedAt: number;             // from the handler, not from when this was first seen
    progress: number | undefined;
    progressMessage: string | undefined;
    taskIds: string[];             // the tasks seen reporting this job and not yet completed
}
```

- `applyJobProgress(jobs: IJob[], taskId: string, message: IJobProgressMessage): IJob[]`: finds the job by `message.job.id` or appends a new one; adds `taskId` to `taskIds` if absent; replaces `progress` and `progressMessage`; keeps the earliest `startedAt` seen for the job, so a pass made of several steps reports the age of the pass rather than of its latest step.
- `applyTaskCompleted(jobs: IJob[], taskId: string): IJob[]`: removes `taskId` from whichever job holds it, and removes the job when that was its last one. Returns the same array reference when no job holds the id, so completions of the many tasks that are not jobs cause no re-render.
- `aggregateJobsProgress(jobs: IJob[]): number | undefined`: mean of the numeric `progress` values, ignoring indeterminate jobs; undefined when none are numeric.
- `describeJobsIndicator(jobs: IJob[]): IJobsIndicatorView | undefined`: what the navbar renders: undefined for none, the job's own name for one, `"N background jobs running"` for several, with the aggregate progress.
- `formatElapsed(elapsedMs: number): string`: `"4s"`, `"1m 4s"`, `"2h 1m"`. Coarse on purpose: a job's age is glanced at, not read.

`IJobsIndicatorView` is defined here.

### 6. Jobs context

**File:** `packages/user-interface/src/context/jobs-context.tsx` (new). A thin shell over the functions above.

- `IJobsContext`:
  - `jobs: IJob[]`
  - `cancelJob(id: string): void`: looks the job up and calls `platform.cancelTasks(job.cancelSource)` when it has one. It does not remove the row: the task fails in response to the cancel and its completion removes it, so the row goes when the work does. A rejected cancel is logged and the row stays, which is correct, because the work is still running.
- `JobsContextProvider({ children })`: one effect subscribes to `platform.onTaskMessage` (applying `applyJobProgress` when `message.type === "job-progress"`) and `platform.onTaskComplete` (applying `applyTaskCompleted`). `jobs` is mirrored into a `jobsRef` so `cancelJob` is a stable `useCallback`.
- `useJobs(): IJobsContext` with the standard "throw if no provider" guard.

Exported from `packages/user-interface/src/index.tsx`.

The elapsed-time ticker is deliberately **not** here. A one-second re-render of everything under this provider would re-render the gallery. It lives in the two components that show elapsed time (Step 7 and 8) as a small `useElapsedTick()` hook, so only they repaint.

### 7. Navbar job indicator

**File:** `packages/user-interface/src/components/navbar-jobs-indicator.tsx` (new), mounted in `navbar.tsx` in the right-hand cluster, before the existing sync-state element.

- Reads `useJobs()` and `describeJobsIndicator()`; renders `null` when that is undefined.
- Otherwise `<CircularProgress size="sm" />` (determinate when the aggregate progress is numeric) and the label. When exactly one job is running it also shows its elapsed time in small grey text.
- Clicking dispatches the `photosphere:show-jobs` window event; `main.tsx` listens for it and opens the right sidebar, next to the existing window-event listeners there.
- `data-id="navbar-jobs-indicator"`, plus `data-id="navbar-jobs-count"` carrying the number of running jobs as text, so a smoke test can read the count without racing a spinner. This mirrors how `navbar-sync-state` is already used.

### 8. Right sidebar jobs list

**File:** `packages/user-interface/src/components/sidebar-jobs-list.tsx` (new), mounted as the first section in `right-sidebar.tsx`, above "Selection".

- Reads `useJobs()`; renders `null` when there are no jobs.
- Otherwise a `Divider` and a `CollapsibleSection` labelled "Background jobs", matching the other sidebar sections, then one row per job:
  - the job's `name`, with `formatElapsed(now - job.startedAt)` beside it in small grey text;
  - `progressMessage` under it in small grey text when present;
  - a `<LinearProgress />`, determinate when `progress` is numeric and indeterminate otherwise;
  - when the job has a `cancelSource`, an icon-only `IconButton` (`size="sm"`, `variant="plain"`, `color="danger"`, `aria-label="Cancel job"`, `title="Cancel"`) calling `cancelJob(job.id)`.
- `data-id`: `sidebar-jobs-list`, `sidebar-job-row-{job.id}`, `sidebar-job-cancel-{job.id}`, `sidebar-job-elapsed-{job.id}`.

### 9. Mount the provider

`<JobsContextProvider>` goes inside `PlatformContextProvider` and outside `AssetDatabaseProvider` in `apps/desktop-frontend/src/app.tsx`, `apps/dev-frontend/src/app.tsx`, the mobile app entry, and `packages/user-interface/src/stories/mocks/index.tsx`.

The stories mock platform's `onTaskMessage` / `onTaskComplete` are already no-ops, so stories show no jobs. Add a story that supplies a fixed `IJobsContext` value directly, the way the import stories already bypass `ImportContextProvider`, so the indicator and the list can be seen and checked at phone resolution.

### 10. Replicate: run in background, and honour cancellation

**File:** `packages/user-interface/src/components/replicate-database-dialog.tsx`.

The dialog passes `onClose={step === "running" ? undefined : onClose}`, which locks it open for the whole replication. Pass `onClose` unconditionally and add a *Run in background* button (`data-id="replicate-run-in-background-button"`) to the `running` step's actions, calling `onClose`. The replication is unaffected: `replicateDatabase()` is awaited by a promise the dialog owns and closing does not cancel anything. From then on the sidebar row is where it is watched and cancelled.

**File:** `packages/node-api/src/lib/replicate.ts`.

Nothing in the replicate loops checks for cancellation, so Cancel would not interrupt an in-flight copy. Add a `throwIfCancelled(isCancelled)` helper called at the per-file copy loop and at the per-merkle-node loops, with `replicate-database.worker.ts` passing `() => context.isCancelled()`. On cancel the copy stops and the task surfaces as failed, which removes the row.

Import and load-assets already honour `context.isCancelled()`.

### 11. Docs

- **`CLAUDE.md`**: add the Job Manager rule:

  > Background work the user should be able to see and stop is grouped into jobs. Whatever queues the task puts an `IJobTag` (`id`, `name`, and `cancelSource` when it can be cancelled) in the task's input data, and the handler reports progress with `sendJobProgress`. Jobs live only in the frontend: it counts the tasks reporting each id and drops the row when the last one completes. Do not keep job state in a worker pool or a worker, and do not give a flow its own progress UI: the shared navbar indicator and the sidebar jobs list show all of it.

- **`docs/background-tasks.md`**: a "Surfacing a task as a job" section covering the tag, `sendJobProgress`, when to leave `cancelSource` out, and when not to tag a task at all.

## Unit tests

- **`packages/user-interface/src/test/lib/jobs.test.ts`** (new):
  - `applyJobProgress` appends a job the first time an id is seen and updates it after that; a second task id reporting the same job is added to `taskIds` without creating a second row; the earliest `startedAt` is kept when steps report different ones; `progress` and `progressMessage` are replaced.
  - `applyTaskCompleted` removes one task id and keeps the job while another remains; removes the job when the last one goes; returns the same array reference for an id no job holds.
  - `aggregateJobsProgress` averages numeric progress, ignores indeterminate jobs, and returns undefined when all are indeterminate.
  - `describeJobsIndicator` returns undefined for none, the job's name for one, and the count label for several.
  - `formatElapsed` for seconds, minutes and hours, and at each boundary.
- **`packages/task-queue/test/job-progress.test.ts`** (new): `sendJobProgress` sends a well-formed `job-progress` message, and sends nothing at all when the tag is undefined.
- **`packages/node-api/src/test/lib/import-assets.worker.test.ts`** (extend): an import whose data carries a job tag emits `job-progress` carrying that tag; one without a tag emits none.
- **`load-assets.worker`, `replicate-database.worker`, `sync-database.worker` tests** (extend, or add where absent): each emits `job-progress` carrying the tag from its input data.
- **`packages/node-api/src/test/lib/replicate.test.ts`** (extend): the copy loop stops once `isCancelled()` turns true and the outstanding files are not copied.

No component tests: the indicator and the list are thin shells over `lib/jobs.ts`, which is what is tested.

## Smoke tests

Existing tests are the proof that no flow regressed:

- **Load assets**: [3-open-database](apps/desktop/smoke-tests/3-open-database/), [10-view-database](apps/desktop/smoke-tests/10-view-database/). No edits expected.
- **Import**: [4-import-photos](apps/desktop/smoke-tests/4-import-photos/), [33-import-cancel](apps/desktop/smoke-tests/33-import-cancel/). No edits expected.
- **Replicate**: [17-replicate-database](apps/desktop/smoke-tests/17-replicate-database/), [27-s3-replicate](apps/desktop/smoke-tests/27-s3-replicate/). Required edit: the running step now exposes `replicate-run-in-background-button` and the dialog can be closed mid-task, so any wait that relies on it staying open changes.
- **Sync**: [24-sync-settings](apps/desktop/smoke-tests/24-sync-settings/). No edits expected.

New coverage, extending [17-replicate-database](apps/desktop/smoke-tests/17-replicate-database/): start a replication, click *Run in background*, assert `sidebar-job-row-*` appears with an elapsed time, and assert it is gone once the replication completes. That is the one end-to-end proof that a job appears, is watchable outside the flow that started it, and clears itself.

Mobile is covered by the existing mobile suites continuing to pass; the job code adds no mobile-specific path.

## Verify

1. `bun run compile` from the repo root, clean.
2. `bun run tev` from the repo root, green.
3. `bun run stories:and`: check the navbar indicator and the sidebar jobs list fit at phone resolution.

## Notes

- **The job's tasks are the ones that report it.** Child tasks (`hash-file`, `upload-asset`) carry no tag and are invisible to the interface, which is right: they are internal to their parent, and the parent does not finish before they do, so the row is up for exactly as long as the work is. Mobile's sync pass, which is a list of steps sharing one job id, is why the row counts task ids rather than assuming one.
- **Elapsed time comes from the worker.** The handler stamps `startedAt` when it begins and resends it with every progress report, so a job already running when the app returns to the foreground shows its real age instead of restarting from zero. Worker and interface are on the same device on every platform, so there is one clock.
- **A missed message is self-correcting.** Every `job-progress` carries the whole tag, so an interface that was not listening when a job started picks it up whole on the next report. The one gap left is a job whose task completes while a mobile WebView is suspended: its row would linger until the app is next started. Every job here reports on a timer while it runs, so this only bites for a job that ends inside the suspension.
- **Cancel does not optimistically remove the row.** It calls `platform.cancelTasks` and waits for the task's completion, so the row disappears when the work does rather than when the button was pressed.
- **Nothing else changes.** `IQueueBackend`, `ITaskQueue`, `addTask`, `ITask`, `ITaskContext`, every worker pool, every IPC and WebSocket payload, both native plugins, `IPlatformContext`, the toast system and the sync trigger logic are untouched.
