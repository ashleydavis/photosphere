# Let a consolidation run in the background, as a replication does

## Overview

While "Consolidate into remote" runs, its dialog offers a button labelled "Cancel". Pressing it closes the dialog and resets its form and the consolidation carries on with no sign anywhere that it is still going and no word when it ends or fails. The Replicate dialog handles the same situation openly: while it runs it says the work continues in the background, its button is labelled "Run in background", the task carries a job tag so it appears in the Background jobs list and the main process tells the user when it ends. This plan gives Consolidate the same treatment. It does not make consolidation cancellable from the interface, for the reason in Notes, so its job row has no Cancel button.

## Issues

- `packages/user-interface/src/components/consolidate-database-dialog.tsx` shows `{step === "success" ? 'Done' : 'Cancel'}` on `consolidate-database-close` in every step, including `running`. `close()` resets the form and calls `onClose`; both parents (`packages/user-interface/src/pages/databases/databases-page.tsx` and `packages/user-interface/src/components/database-summary-view.tsx`) then unmount the dialog. `consolidate()` keeps awaiting the task, which is not cancelled: `queue.shutdown()` only runs in its `finally`.
- The `consolidate-database` task carries no job tag (`IConsolidateDatabaseData` in `packages-zig/node-api-zig/src/lib/consolidate-database.worker.zig` has no `job` field and the handler never calls `sendJobProgress`), so a consolidation is invisible once its dialog is gone.
- `handleTaskEnd` in `packages-zig/photosphere-core/src/lib/main-process.zig` notifies the user when a `replicate-database` task ends and has no case for `consolidate-database`.

## Steps

1. **Report the consolidation as a job.** In `packages-zig/node-api-zig/src/lib/consolidate-database.worker.zig`:
    - Import `IJobTag = task_queue_zig.types.IJobTag` and `sendJobProgress = task_queue_zig.job_progress.sendJobProgress`, as `replicate-database.worker.zig` does.
    - Add `job: ?IJobTag = null` to `IConsolidateDatabaseData`, with a comment: the job the consolidation belongs to, so it is listed in the interface's Background jobs while it runs; null for the CLI, which lists no jobs.
    - Give `ProgressMessageSender` two more fields, `job: ?IJobTag` and `runStartedAt: i64`, each with a comment and in `send`, after `self.context.sendEvent(...)`, call `sendJobProgress(allocator, io, log, self.context, self.job, self.runStartedAt, <text>)` where the text is `std.fmt.allocPrint(allocator, "{d} of {d} photos uploaded", .{ pushed, total })`. `send` has no return value, so a failure of either call panics with a sentence naming it, as the two existing calls in `send` already do.
    - In `consolidateDatabaseHandler`, take `const runStartedAt = context.timestampProvider.now(io);` after the data checks and send `sendJobProgress(allocator, io, log, context, data.job, runStartedAt, "Opening the remote")` straight away, before `openStorage` runs, so the row appears even while the remote is slow to answer. Send `"Downloading the remote's records"` the same way just before `prefetchDatabaseHandler`. Fill the two new `ProgressMessageSender` fields.
    - Check `apps/cli-zig/src/cmd/consolidate.zig` `consolidateDatabaseDataToJson` still compiles and still sends no `job` (the field defaults to null).
    Add the unit tests in Unit Tests to `packages-zig/node-api-zig/src/test/consolidate-database.worker.test.zig`, reading the recorded events the way the existing "streams progress as assets are pushed" test does and the way `replicate-database.worker.test.zig` "reports its job alongside each progress string" filters for `job-progress`. Run `bun run test:zig` and watch it pass.

2. **Tell the user when a consolidation ends.** In `packages-zig/photosphere-core/src/lib/main-process.zig` `handleTaskEnd`, after the `replicate-database` block, add a block for `consolidate-database`:
    - Parse `IConsolidateInputs`, a new struct beside `IReplicateInputs` with one field `remotePath: []const u8 = ""` and a comment, from `end.input_json` with `.ignore_unknown_fields = true`.
    - On `.succeeded`, `log.event` and `events.sendShowNotification` the message `Consolidated into "<basename of remotePath>"` with color `success`, using `node_utils.path.basename` as `handleReplicateSucceeded` does.
    - Otherwise send the notification `Consolidation failed: <errorMessageOrUnknown(end.error_message)>` with color `danger` and duration `8000`, as the replicate failure does.
    - Add the clause "tells the user when a consolidation ends" to the comment above `onTaskEnd`.
    Add the main-process test in Unit Tests to `packages-zig/photosphere-core/src/test/main-process.test.zig`, modelled on "a replication that worked registers its destination and tells the user". Run `bun run test:zig` and watch it pass.

3. **Tag the task from the dialog and offer "Run in background".** In `packages/user-interface/src/components/consolidate-database-dialog.tsx`:
    - In `consolidate()`, add a `job` property to the task data, written across lines: `id: `consolidate:${entry.path}``, `name: `Consolidating into ${remoteName}`` and no `cancelSource`. `remoteName` is `trimmedRemote.split(/[\\/]/).filter(Boolean).pop() ?? trimmedRemote`, the same expression `packages/node-api/src/lib/replicate-database.ts` uses for a destination name, with `trimmedRemote` being `remotePath.trim()` computed once and also used for `remotePath` in the data. Import `type IJobTag` from `task-queue` and type the tag with it.
    - Replace the single `consolidate-database-close` button with one button per step, as the Replicate dialog does: in `configure`, `consolidate-database-close` labelled `Cancel`; in `running`, `consolidate-run-in-background-button` labelled `Run in background`, `variant="plain"`, calling `close`; in `success`, `consolidate-database-close` labelled `Done`; in `error`, `consolidate-database-close` labelled `Close`.
    - Under the spinner in the `running` step, add `<Typography level="body-sm" color="neutral" data-id="consolidate-background-hint">Consolidation runs in the background. You can close this dialog and it will keep going; watch it from the Background jobs list in the menu.</Typography>`.
    - Rewrite the comment above the component to say the dialog can be closed while the consolidation runs, that closing hands it to the Background jobs list without cancelling it and that the main process tells the user how it ended.
    `bun run compile` passes.

4. **Add pause and resume helpers for the S3 emulator.** In `apps/photosphere-smoke-tests/lib/common.sh`, beside `stop_s3_emulator`, add these two functions unless they are already there:
    - `pause_s3_emulator <state-dir>`: reads `<state-dir>/minio.pid` (written by `scripts/s3-emulator.sh` when it starts the server) and sends that one pid `kill -STOP`. Fails the test with `log_error` and `exit 1` when the file is missing or the signal cannot be sent.
    - `resume_s3_emulator <state-dir>`: sends the same pid `kill -CONT`. Never fails and returns 0, including when no server was started, so it is safe in a cleanup trap.
    Each gets a comment block saying what it is for: a stopped server accepts connections and answers none, which holds an S3 request in flight for as long as a test needs, without a timer. Both signal the recorded pid only, never a process found by name.

5. **Add smoke scenario `apps/photosphere-smoke-tests/68-consolidate-in-background/test.sh`.** Header comment saying it holds a consolidation in flight by pausing the S3 server the remote lives on, hands it to the background and checks it finishes and says so. It runs on every platform. Its steps:
    - `S3_STATE_DIR="$TMP_DIR/s3"`, `SECRET_NAME="smoke-test-s3"`. A `cleanup` function that runs `resume_s3_emulator "$S3_STATE_DIR"`, then `cleanup_apps "$TMP_DIR"`, then `stop_s3_emulator "$S3_STATE_DIR"`, installed with `trap cleanup EXIT`. `start_s3_emulator "$S3_STATE_DIR"`.
    - The remote: export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL` and `AWS_REGION` from the emulator's values, as `45-s3-share-replica-sync/test.sh` does and with `REMOTE_PATH="s3:$S3_EMULATOR_BUCKET/remote-db"` run `run_zig_cli "$TMP_DIR" init --db "$REMOTE_PATH" --yes` and `run_zig_cli "$TMP_DIR" add "$REPO_DIR/test/test.webp" --db "$REMOTE_PATH" --yes`, failing the test on a non-zero exit.
    - The local database: `create_database "$TMP_DIR/local-db" "$REPO_DIR/test/test.png"`, `"${PLATFORM}_reset_app_state"`, `"${PLATFORM}_seed_database" "$TMP_DIR/local-db" "local-db"` and `"${PLATFORM}_seed_databases_config"` with `[{name: "Local", path: <app path of local-db>}, {name: "Remote", path: $REMOTE_PATH, s3Key: $SECRET_NAME}]`. The consolidation task finds the remote's S3 credentials through that second record.
    - `start_app`, `wait_for_ready`, navigate to `secrets`, wait for `Secrets page loaded`, `add_s3_secret_via_ui "$APP_PORT" "$SECRET_NAME" "$S3_ENDPOINT" "us-east-1" "$S3_EMULATOR_ACCESS_KEY" "$S3_EMULATOR_SECRET_KEY"`.
    - Navigate to `databases`, wait for `Databases page loaded`, `click_database_row_action "$APP_PORT" 0 consolidate-database-button`, wait for `Consolidate into remote dialog opened`, type `$REMOTE_PATH` into `consolidate-remote-path-input`.
    - `pause_s3_emulator "$S3_STATE_DIR"`, click `consolidate-database-confirm`.
    - `wait_for_value "$APP_PORT" consolidate-background-hint "keep going"` and `wait_for_value "$APP_PORT" consolidate-run-in-background-button "Run in background"`. `wait_for_log "$TMP_DIR" "Background job started: Consolidating into remote-db"` (logged by `packages/user-interface/src/context/jobs-context.tsx` when a job row appears).
    - Click `consolidate-run-in-background-button`, then `wait_for_value_gone "$APP_PORT" consolidate-run-in-background-button "Run in background" || exit 1`.
    - `resume_s3_emulator "$S3_STATE_DIR"`. `wait_for_value "$APP_PORT" toast-message 'Consolidated into "remote-db"' 120`.
    - Read the remote back with `run_zig_cli "$TMP_DIR" summary --db "$REMOTE_PATH" --yes` and assert it reports two photos, using the line `psi summary` prints for the file count (read `apps/cli-zig/src/cmd/summary.zig` for its exact label before writing the match).
    - `check_no_errors "$TMP_DIR"`, `stop_app`, `log_success "Test 68 passed: consolidate-in-background"`.
    Run `PHOTOSPHERE_SMOKE_SCENARIO=68 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=68 bun run test:ziggy:and` and watch both pass.

6. **Check the existing consolidate scenario.** `apps/photosphere-smoke-tests/36-consolidate-database/test.sh` clicks `consolidate-database-close` on the success step, which still exists with the label `Done`. Run `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy:and` and watch both pass.

7. **Update the documentation to match the code.**
    - `docs/tasks.md`, "Surfacing a task as a job": add consolidation beside background sync as a job that leaves `cancelSource` out, with the reason from Notes in one sentence.
    - `docs/syncing.md`: wherever it describes consolidating into a remote, add that the dialog can be closed while it runs, that it is then listed in Background jobs and that a notification says how it ended.
    - `docs/testing/e2e/desktop/database/consolidate-in-background.md` and `docs/testing/e2e/mobile/database/consolidate-in-background.md`: new manual tests in the layout of `docs/testing/e2e/desktop/database/edit-database-origin.md`. Each consolidates a database with enough photos to take a while into a remote, presses **Run in background** (`consolidate-run-in-background-button`), checks the Background jobs list shows "Consolidating into ..." with no Cancel button and checks the notification when it ends. List each in its folder's `README.md` and add `- [ ]` entries under "Database" in the Desktop and Mobile sections of `docs/testing/e2e/CHECKLIST.md`.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`: a "Consolidating into a remote" paragraph after "Replicating a Database" saying what the dialog asks for, that it can run in the background and that it cannot be cancelled once started.
    - `packages/user-interface/src/stories/dialogs/consolidate-database-dialog.stories.tsx`: a new story `consolidate-database-dialog/open` in the layout of `replicate-database-dialog.stories.tsx`, rendering `ConsolidateDatabaseDialog` with a sample entry inside `MockProviders` and `StoryModalLauncher`. Register it in `packages/user-interface/src/stories/index.ts` with one import and one spread. Run `bun run stories:ziggy -- --headless --no-screenshots` and watch it report no failed story.

## Unit Tests

- `packages-zig/node-api-zig/src/test/consolidate-database.worker.test.zig`:
    - "reports its job while it runs, carrying the tag it was queued with": queue data with a `job` tag; the recorded `job-progress` events start with `Opening the remote`, include `1 of 1 photos uploaded` and end with `Downloading the remote's records` and each carries the tag's id and name.
    - "reports no job when the consolidation was queued without a tag": the same run without `job` records no `job-progress` event and the `consolidate-progress` events are unchanged.
- `packages-zig/photosphere-core/src/test/main-process.test.zig`, "a consolidation that worked tells the user and one that failed tells the user why": end a `consolidate-database` task with input `{"databasePath":"/photos","remotePath":"s3:bucket/remote-db"}` as succeeded and wait for the `show-notification` with `Consolidated into \"remote-db\"` and `success`; end another as failed with `error_message` `"Remote unreachable"` and wait for `Consolidation failed: Remote unreachable` with `danger`.
- No unit test for the dialog: it is a React component. Step 5 covers it. No new TypeScript lib function: the job tag is three literal fields and the name expression already exists in `replicate-database.ts`.

## Smoke Tests

- `apps/photosphere-smoke-tests/68-consolidate-in-background` (new), host and Android: while the remote's server is paused the dialog shows the background hint and the Run in background button, the job appears, the dialog closes on the button and after the server resumes the success notification appears and the remote holds both photos.
- `apps/photosphere-smoke-tests/36-consolidate-database`, host and Android: unchanged and still passing.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `bun run test:zig` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=68 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=68 bun run test:ziggy:and` exit 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy:and` exit 0.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- Decided: match Replicate's "Run in background" and do not make consolidation cancellable. `consolidateDatabases` in `packages-zig/node-api-zig/src/lib/consolidate.zig` pushes assets into the remote and saves the remote's merkle tree only at the end of `pushAbsentAssets`, then `joinAsPartialReplica` deletes the local `.db/bson` and replicates the remote's records down. Stopping inside the first part leaves files in the remote that its tree does not list; stopping inside the second leaves the local database with its records deleted and the remote's not yet copied. Making either safe needs a resumable design, which is a separate piece of work. A job without `cancelSource` is the documented way to show work that cannot be stopped from the interface (`docs/tasks.md`).
- The job id is `consolidate:<local database path>`, because one local database is consolidated at a time and the path is what tells two consolidations apart. The name uses the remote's last segment, as a replication's name uses its destination's.
- The end notification comes from the main process, as a replication's does, so it is sent on every platform whether or not the dialog is still open. While the dialog is open the user sees both the dialog's success step and the notification, which is also what Replicate does.
- The dialog's own promise still runs after the dialog closes and its `setStep` calls land on an unmounted component, which React 18 ignores. `queue.shutdown()` still runs in its `finally` once the task ends, so the queue is not left behind.
- The smoke scenario pauses the S3 server rather than relying on a large batch being slow enough. A batch that is fast on one machine finishes before the button is clicked, while a paused server holds the first remote request for exactly as long as the test needs. Pausing is by the pid the emulator script recorded, never by name, so a run in another worktree is untouched.
- The CLI's `psi consolidate` queues the same task without a `job`, so `sendJobProgress` sends no job event there.
