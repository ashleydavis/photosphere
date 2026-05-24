# Job Manager

## Managed Background Jobs

The following background activities will be surfaced through the Job Manager:

- **Import Assets** — registered from the import context when a new import session starts; cancellable. Progress is reported as *"N of M files"* as the worker processes each asset.
- **Load Assets** — registered from `AssetDatabaseSource` when a database starts loading; cancellable. Progress is reported as *"N assets loaded"* (indeterminate unless the merkle tree provides a total).
- **Replicate Database** — registered from the Replicate dialog when replication starts; cancellable. Progress is reported as the per-file status string emitted by the replicate worker. The dialog becomes dismissable mid-task via a *Run in background* button.
- **Sync Database** — registered when `platform.onSyncStarted()` fires; not cancellable in v1. Progress is indeterminate.
- **Verify Database** (future) — to be registered when the Verify flow is implemented, following the same pattern (see Step 9 and the Notes section).

## Overview

Today the app surfaces background work in scattered, ad-hoc ways: the Import context owns the import session, `AssetDatabaseSource` owns the load-assets queue, the Replicate dialog locks itself open until completion, and sync runs silently. There is no app-level concept of "a piece of background work the user can see and cancel". This plan introduces a centralised **Job Manager** that models each user-visible background activity as an `IJob`, exposes it through a React context, and renders it in two UI surfaces: a compact indicator in the right of the navbar (single job name + spinner, or *"N jobs running"* when multiple) and a list in the right sidebar (per-job progress + Cancel). The existing flows (Import Assets, Load Assets, Replicate Database) are converted to register jobs through this manager; a future Verify Database flow can adopt the same pattern with no further plumbing.

## Issues
<!-- populated later by plan:check -->

## Steps

### 1. Define the job model

**1a. New file `packages/user-interface/src/context/jobs-context.tsx`.**

Define and export:

- `IJob` interface:
  - `id: string` — stable job id, used as React key and lookup key. Reuse the existing tag where possible: `sessionId` for import, the database path for load-assets / sync, the source path for replicate.
  - `name: string` — human-readable label, e.g. *"Importing 124 photos"*, *"Loading database 'Family'"*, *"Replicating to /backups/photos"*.
  - `sourceTag: string` — the value to pass to `platform.cancelTasks(sourceTag)` to terminate this job's worker tasks. Often equal to `id`; kept as a separate field so jobs that don't map 1:1 to a task source can still cancel correctly.
  - `progress: number | undefined` — fractional progress in `0..1`. Undefined means indeterminate (show a spinner instead of a bar).
  - `progressMessage: string | undefined` — short human-readable detail (e.g. *"Copying display.jpg"* for replicate, *"123 of 500"* for import).
  - `cancellable: boolean` — whether the Cancel button is rendered for this job.
  - `startedAt: number` — `Date.now()` at registration; used to sort the sidebar list.

- `IJobsContext` interface (provided to consumers via a React context):
  - `jobs: IJob[]` — current jobs in registration order.
  - `registerJob(job: IJob): void` — add or replace a job (idempotent on `id`).
  - `updateJob(id: string, patch: Partial<Omit<IJob, "id">>): void` — merge a partial update into a registered job; no-op if the id is unknown.
  - `completeJob(id: string): void` — remove the job from the list.
  - `cancelJob(id: string): void` — calls `platform.cancelTasks(job.sourceTag)` and immediately removes the job.

- `JobsContextProvider({ children })` component:
  - Holds `jobs` state (array of `IJob`, ordered by `startedAt`).
  - Provides the four methods above. Implementations operate on the array using stable referential updates.
  - Reads `platform` from `usePlatform()` so `cancelJob` can route through `platform.cancelTasks`.

- `useJobs(): IJobsContext` hook with the standard "throw if no provider" guard.

### 2. Mount the provider at app level

**File:** `packages/user-interface/src/main.tsx`.

- Wrap the existing top-level component tree (inside any `PlatformContextProvider`, since `JobsContextProvider` uses `usePlatform`) in `<JobsContextProvider>`. Placement: outside `AssetDatabaseProvider` and the gallery/import contexts so all flows see the same instance.

### 3. Navbar job indicator

**3a. New file `packages/user-interface/src/components/navbar-jobs-indicator.tsx`.**

- React component, no props, reads `useJobs()`.
- Render rules:
  - When `jobs.length === 0`: render `null`.
  - When `jobs.length === 1`: render a `<Box>` with a `<CircularProgress size="sm" />` (determinate when `progress !== undefined`, indeterminate otherwise) and the job's `name`. If `progress !== undefined`, render the percentage in small grey text after the name.
  - When `jobs.length > 1`: render `<CircularProgress size="sm" />` and the text *"N background jobs running"*. The aggregated progress should be the mean of jobs that have a numeric `progress`; ignore indeterminate jobs in the aggregate.
- Clicking the indicator dispatches a custom DOM event `photosphere:show-jobs` that the layout listens for (see Step 4b). Avoid coupling this component directly to sidebar state.
- Use a `data-id="navbar-jobs-indicator"` attribute on the root for smoke-test selection.

**3b. Mount in the navbar.**

**File:** `packages/user-interface/src/components/navbar.tsx`.

- Import `NavbarJobsIndicator` and render it in the right-hand region of the navbar, immediately before any existing right-side controls (e.g. the update-available pill, upload button). Use the same `Box` flex layout the navbar uses for its right cluster.

### 4. Right sidebar jobs list

**4a. New file `packages/user-interface/src/components/sidebar-jobs-list.tsx`.**

- Component reads `useJobs()`.
- When `jobs.length === 0`: render `null` (no empty heading).
- Otherwise render:
  - A section header `<Typography level="title-sm">Background jobs</Typography>`.
  - For each job: a row containing
    - the `name`,
    - `progressMessage` underneath in small grey text when present,
    - a determinate `<LinearProgress determinate value={progress*100} />` when `progress` is defined, otherwise an indeterminate `<LinearProgress />`,
    - a `<Button size="sm" variant="plain" color="danger">Cancel</Button>` calling `cancelJob(job.id)` when `job.cancellable` is true.
  - `data-id` attributes: `sidebar-jobs-list`, `sidebar-job-row-{job.id}`, `sidebar-job-cancel-{job.id}`.

**4b. Mount in the right sidebar.**

**File:** `packages/user-interface/src/components/right-sidebar.tsx`.

- Import `SidebarJobsList` and render it as the first section above existing content, with appropriate `Divider` spacing.

**4c. (Optional but recommended) Auto-open the right sidebar when the navbar indicator is clicked.**

**File:** `packages/user-interface/src/main.tsx` (the layout component holding the right-sidebar open state).

- Add a `useEffect` that subscribes to the `photosphere:show-jobs` window event and opens the right sidebar. Clean up the listener on unmount.

### 5. Refactor Import flow to register a job

**File:** `packages/user-interface/src/context/import-context.tsx`.

- Read `useJobs()`.
- When an import session starts (after `platform.importAssets(...)` returns `IImportSession`), call `registerJob({ id: session.sessionId, name: "Importing assets", sourceTag: session.sessionId, progress: undefined, progressMessage: undefined, cancellable: true, startedAt: Date.now() })`.
- In the existing `onTaskMessage` handler that processes `import-success` / `import-failed` / `import-skipped` / `import-pending`, also call `updateJob(session.sessionId, { progressMessage: \`${processed} of ${pending + processed} files\` })`. Compute a numeric `progress` when both numerator and denominator are known.
- When the `importAssetsTaskId` task completes (success, fail, or cancel), call `completeJob(session.sessionId)`.
- Refine the job `name` once the scan phase reports a final total, e.g. *"Importing 248 files"*.

### 6. Refactor Load Assets flow to register a job

**File:** `packages/user-interface/src/context/asset-database-source.tsx`.

- Use `useJobs()`.
- In the loader that calls `loadAssetsApi(queue, dbPath)`:
  - Right before queueing the task, `registerJob({ id: dbPath, name: \`Loading database "${name}"\`, sourceTag: dbPath, progress: undefined, progressMessage: undefined, cancellable: true, startedAt: Date.now() })`. Use the database name when available (look up from the platform databases list or pass it in); fall back to `basename(dbPath)`.
  - In the existing `asset-page` message subscriber, accumulate the count of received assets and call `updateJob(dbPath, { progressMessage: \`${count} assets loaded\` })`. If the merkle tree or metadata provides a total, compute and pass `progress`. Otherwise leave it indeterminate.
  - In the `onTaskComplete` handler that flips `isLoading` to false, call `completeJob(dbPath)`.
- In `cancelDatabaseLoad(dbPath)`, also call `completeJob(dbPath)` so a user-driven cancel removes the row immediately rather than waiting for the queue to settle.

### 7. Refactor Replicate flow to register a job

The dialog should no longer be the owner of the running state — the Job Manager is.

**7a. Allow the dialog to close while the task is running.**

**File:** `packages/user-interface/src/components/replicate-database-dialog.tsx`.

- Change `<Modal onClose={step === "running" ? undefined : onClose}>` to `<Modal onClose={onClose}>`. The dialog is dismissable at any time.
- Replace the *Running* DialogActions with a single `<Button data-id="replicate-run-in-background-button">Run in background</Button>` that calls `onClose`. Drop the spinner-only progress step.

**7b. Register a job from the dialog's `handleStart`.**

- Use `useJobs()`.
- Just before calling `replicateDatabase(...)`, `registerJob({ id: taskData.sourcePath, name: \`Replicating to ${taskData.destPath}\`, sourceTag: taskData.sourcePath, progress: undefined, progressMessage: undefined, cancellable: true, startedAt: Date.now() })`.
- Convert the existing `setProgress` callback so it *also* writes to the job: `updateJob(id, { progressMessage: progress })`. The dialog can keep its inline progress display for as long as the user keeps the dialog open.
- On success, call `completeJob(id)`; on error, call `completeJob(id)` *before* surfacing the failure toast/inline alert.

**7c. Make the replicate worker honour cancellation.**

**File:** `packages/api/src/lib/replicate.ts`.

- Add `context.isCancelled()` checks at the natural loop boundaries inside `replicate()` and its helpers (per-file copy loop, per-merkle-node loop). When cancelled, abort cleanly and let the worker handler surface `TaskStatus.Failed`.
- **File:** `packages/api/src/lib/replicate-database.worker.ts` already returns from `replicate()` — no further change needed beyond the inner cancellation checks.

### 8. Refactor Sync flow to register a job

**File:** `packages/user-interface/src/context/asset-database-source.tsx` (the sync-started/sync-completed subscriptions live here).

- On `platform.onSyncStarted()`: `registerJob({ id: \`sync:${currentDatabasePath}\`, name: \`Syncing database "${name}"\`, sourceTag: currentDatabasePath!, progress: undefined, progressMessage: undefined, cancellable: false, startedAt: Date.now() })`. (Cancellation of sync is out of scope; mark `cancellable: false`.)
- On `platform.onSyncCompleted()`: `completeJob(\`sync:${currentDatabasePath}\`)`.

### 9. Provide a hook for future flows (Verify, etc.)

No code change. Document the pattern at the top of `jobs-context.tsx`:

> Adding a new background job: call `registerJob()` when work starts, `updateJob()` from any progress callback, and `completeJob()` from both success and failure paths. Set `sourceTag` to whatever string the worker handler tagged its tasks with so `cancelJob()` can route through `platform.cancelTasks()`.

### 10. Update CLAUDE.md

**File:** `CLAUDE.md`.

- Add a one-line rule under *Architecture* or a new *UI* section:

> User-visible background activities (Import, Load Assets, Replicate, Sync, Verify) must register themselves with the Job Manager via `useJobs().registerJob()` so they appear in the navbar indicator and sidebar list. Do not create flow-specific progress UI in components — update the job and rely on the shared indicator/list.

## Unit Tests

- **`jobs-context.test.tsx`** (new): render `JobsContextProvider` wrapping a test consumer; assert
  - `registerJob` adds a job, repeated registration with the same id replaces in place;
  - `updateJob` merges fields and is a no-op for unknown ids;
  - `completeJob` removes by id;
  - `cancelJob` invokes `platform.cancelTasks(sourceTag)` (mock the platform) and removes the job.
- **`navbar-jobs-indicator.test.tsx`** (new): render the component within a stubbed `JobsContext` value; assert
  - renders nothing for 0 jobs,
  - renders job name for 1 job,
  - renders *"N background jobs running"* for >1 jobs,
  - aggregate progress is the mean of numeric `progress` values.
- **`sidebar-jobs-list.test.tsx`** (new): render with stubbed jobs; assert
  - empty state renders nothing,
  - one row per job,
  - Cancel button calls `cancelJob(job.id)` and is hidden when `cancellable === false`,
  - determinate vs. indeterminate `<LinearProgress />` based on `progress`.
- Extend existing import-context / asset-database-source tests (if any) so they don't regress when the new `useJobs()` call is added; if no existing test covers the new call paths, add one in `packages/user-interface/src/test/context/`.
- Extend `replicate-database-dialog` tests (if any sibling tests exist; check `packages/user-interface/src/test/components/`) to assert the running-step now exposes the *Run in background* button.

## Smoke Tests

Add a new desktop smoke test directory: `apps/desktop/smoke-tests/18-job-manager/test.sh`. Model on `17-replicate-database/test.sh`. The test:

1. Pre-create a source database via CLI with a small fixture.
2. Start the desktop app, open the source database (so the Load Assets job fires briefly), wait for `Databases page loaded`.
3. Open the Replicate dialog, fill `replicate-dest-path-input`, click `replicate-start-button`.
4. Assert the `data-id="navbar-jobs-indicator"` element is visible and its text contains `Replicating to`.
5. Open the right sidebar, click `data-id="sidebar-job-row-${sourcePath}"`, assert the Cancel button is present.
6. Click `data-id="replicate-run-in-background-button"` — the dialog closes and the navbar indicator stays.
7. Wait for `Replication completed for` log line, assert the navbar indicator disappears within 2s.
8. Extend the smoke test runner index if it does not auto-discover the new directory.

Also update the existing **17-replicate-database** smoke test to click the new *Run in background* button mid-task and verify completion still fires correctly.

## Verify

1. `bun run compile` from repo root — clean.
2. `bun run test` from repo root — full unit-test suite green, including the new jobs-context and indicator tests.
3. `bun run test:cli` — no regression in CLI tests.
4. `bun run test:electron` — full smoke suite green, including the new `18-job-manager` and the updated `17-replicate-database`.
5. `grep -c "useJobs" packages/user-interface/src` should be at least 4 (jobs-context, navbar indicator, sidebar list, plus the four flows that register jobs).
6. `grep -c "registerJob\|completeJob\|updateJob" packages/user-interface/src` should match the number of expected call sites (≥ 4 register, ≥ 4 complete, plus update calls).

## Human Verification

1. Start the desktop app (`bun run dev`).
2. Open a registered database — verify a "Loading database" row briefly appears in the right sidebar with an indeterminate progress bar, and a matching navbar indicator. Both disappear when load completes.
3. Trigger an import (drag-drop or File → Import Assets). Confirm a "Importing assets" job appears in both surfaces, progress text counts up, and Cancel terminates the import and removes the row.
4. Open the Replicate dialog from the Manage Databases page, configure a destination, click *Start replication*. Click *Run in background* — the dialog closes, the navbar shows the replicate job, the sidebar shows progress.
5. With the replicate job running, trigger a second job (e.g. open a different database to fire Load Assets). The navbar should switch from showing the single job name to *"2 background jobs running"*; the sidebar should list both rows.
6. Click Cancel on the replicate row — the row disappears and the worker terminates (no more `replicate-progress` log lines arrive).
7. Wait for any remaining job to complete — sidebar empties, navbar indicator disappears.
8. Confirm the toast notifications still fire on replicate completion/failure (they live in main and are independent of the Job Manager).

## Notes

- **Why a context rather than a singleton store?** All consumers are React components, the data is UI-bound, and there are no headless callers. Context is the lighter primitive and keeps SSR/test setup simple.
- **Why `sourceTag` separate from `id`?** The renderer keys jobs by what's most natural to the *user-visible* concept (e.g. database path), but the worker tasks are tagged by what's most natural to the *worker* (e.g. sessionId for import). Decoupling lets the two co-exist without contortions.
- **Aggregated progress in the navbar.** Mean of numeric `progress` ignoring indeterminate jobs is a reasonable default. If the jobs are heterogeneous (one large, one small) this is inaccurate, but the alternative (weighted by job magnitude) needs a `weight` field that we'd have to populate for every flow — not worth it for the navbar's compact summary.
- **Replicate cancellation is the only worker-side code change.** Import and load-assets workers already honour `context.isCancelled()`. Sync is intentionally non-cancellable in v1. Verify (future) will need the same care when added.
- **The dialog keeps its own progress display** so users who *don't* dismiss it still see what's happening. The Job Manager is additive — flows can update both the dialog and the job in lockstep.
- **What this plan does not change.**
  - The `platform.cancelTasks` IPC is unchanged.
  - The `TaskQueue` API is unchanged.
  - The toast notification system is unchanged — toasts on completion/failure still fire from main.
  - The Sync trigger logic (debounce, periodic timer) is unchanged.
- **Future:** when Verify Database is implemented, it should register a job with `id = \`verify:${databasePath}\`` and `sourceTag = databasePath`, and the worker should honour cancellation the same way replicate does.
