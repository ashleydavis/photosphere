# One database name check for every dialog

## Overview

Every dialog that names a database checks the name its own way. Edit compares names with a local `toLowerCase` over the list it was given. Create, Add and Receive ask the core with `platform.findDatabase`. Create, Add and Edit complain about an empty name when the button is pressed, while Receive disables its Save button with no explanation. Replicate does not let the user name the replica at all: the main process names it after the last segment of the destination path when the replication ends and when that name is taken the registration throws, is logged and the user is not told while the dialog says the replica "has been added to your databases". This plan puts the check in one `lib/` function, gives every dialog the same empty-name behaviour and gives Replicate a Name field that the main process uses.

## Issues

- `packages/user-interface/src/components/edit-database-modal.tsx` `handleSave` (around lines 195 to 204) matches names with `String.prototype.toLowerCase`, which folds every Unicode letter. The core matches with `std.ascii.eqlIgnoreCase` (`namesMatch` in `packages-zig/node-api-zig/src/lib/databases-config.zig`), which folds only A to Z. A name that differs from another only in a non-ASCII letter's case is refused by Edit and accepted by the core.
- `packages/user-interface/src/components/create-database-modal.tsx` and `add-database-modal.tsx` `handleCreate` / `handleAdd` call `platform.findDatabase`. `packages/user-interface/src/components/receive-database-dialog.tsx` calls it in `proceedAfterSecretConflicts` and `handleDbNameConflictResolved`.
- Receive's review step disables `receive-database-save-button` with `!editedName || !editedPath`, untrimmed, so a name of spaces passes and an empty one gives no reason. The other dialogs show `Name is required` on click.
- `packages/user-interface/src/components/replicate-database-dialog.tsx` has no name field. `handleReplicateSucceeded` in `packages-zig/photosphere-core/src/lib/main-process.zig` names the record `node_utils.path.basename(inputs.destPath)`; when that is taken `addDatabaseEntry` throws, `handleTaskEnd` logs `Error finalising replicate-database` and no notification is sent.

## Steps

1. **Write the check.** Add `packages/user-interface/src/lib/database-name-check.ts` exporting:
    - `DatabaseNameProblem`, the type `"empty" | "taken"`, with a comment.
    - `IDatabaseNameCheck`, an interface with a commented field each: `trimmedName: string` (the name with surrounding white space removed, which is what gets saved), `problem: DatabaseNameProblem | undefined` (undefined when the name can be used), `message: string | undefined` (the sentence shown under the Name field, undefined when there is no problem) and `takenBy: IDatabaseEntry | undefined` (the record that already holds the name, for Receive's Replace choice).
    - `databaseNamesMatch(left: string, right: string): boolean`, which compares the two after replacing each of `A` to `Z` with its lower case letter and changing no other character, with a comment saying it matches `namesMatch` in `databases-config.zig` exactly so the dialog and the core never disagree about whether a name is taken.
    - `checkDatabaseName(name: string, databases: IDatabaseEntry[], ownName: string | undefined): IDatabaseNameCheck`. It trims the name. Empty gives problem `empty` and message `Enter a name.`. Otherwise it looks for a record whose name matches by `databaseNamesMatch` and whose name does not match `ownName` (so renaming a record to itself, in any letter case, is allowed). Found gives problem `taken`, message `A database named "<trimmed name>" already exists.` (the sentence the core uses) and `takenBy` that record. Otherwise every field but `trimmedName` is undefined.
    Write `packages/user-interface/src/test/lib/database-name-check.test.ts` (see Unit Tests). Run `bun run test -- database-name-check` and watch it pass.

2. **Create and Add use it.** In `create-database-modal.tsx` `handleCreate` and `add-database-modal.tsx` `handleAdd`, replace the empty check and the `platform.findDatabase` call with `const nameCheck = checkDatabaseName(form.name, await platform.getDatabases(), undefined);`, then `if (nameCheck.message !== undefined) { setNameError(nameCheck.message); return; }` and use `nameCheck.trimmedName` where `trimmedName` was used. In Create, remove `|| nameError !== undefined` from the `disabled` of `create-database-confirm` and from the `createDialogKeyHandler` call: pressing Create again re-runs the check and the error under the Name field already says why. Add Database gets the same `nameError` state, `FormControl error={nameError !== undefined}`, clearing on change and `Typography` under its Name input that Create has, so both dialogs show the message the same way. In both dialogs give that `Typography` `data-id="database-name-error"`. `bun run compile` passes.

3. **Edit uses it.** In `edit-database-modal.tsx` `handleSave`, replace the empty check and the `isRenameToSelf` / `collision` block with `checkDatabaseName(form.name, await platform.getDatabases(), entry?.name)` and the same `setNameError` and return. Use `nameCheck.trimmedName` for `entryData.name`. Give the name error `Typography` `data-id="edit-database-name-error"`. The `databases` prop stays: `originCandidates` still uses it. Update the prop's comment to say it is the list origin candidates are picked from. `bun run compile` passes.

4. **Receive uses it, with the same empty-name behaviour.** In `receive-database-dialog.tsx`:
    - Add state `const [nameError, setNameError] = useState<string | undefined>(undefined);` with a comment, cleared when the dialog resets and when `receive-database-name-input` changes. Wrap the review step's Name input in `FormControl error={nameError !== undefined}` and render the message under it in `Typography` with `data-id="receive-database-name-error"`, as Create does.
    - Change `disabled` on `receive-database-save-button` and the review term of `dialogConfirmDisabled` from `!editedName || !editedPath` to `editedPath.trim().length === 0`. If those expressions have since been replaced by a call to a function in `packages/user-interface/src/lib/confirm-reasons.ts` that also takes the name, remove the name argument and its rule and its test from that function instead.
    - At the top of `handleSave`'s `try`, run `checkDatabaseName(editedName, await platform.getDatabases(), undefined)`. For problem `empty`, set `nameError` and return, staying on the review step. For `taken` or none, carry on as today: secret conflicts first, then `proceedAfterSecretConflicts`.
    - In `proceedAfterSecretConflicts`, replace `platform.findDatabase(trimmedName)` with a fresh `checkDatabaseName` and use `takenBy` for `setExistingDbName(...)`.
    - In `handleDbNameConflictResolved`, replace the empty check and `platform.findDatabase(trimmedRename)` with `checkDatabaseName(dbNameConflictRename, await platform.getDatabases(), undefined)` and `setDbNameConflictRenameError(check.message)`. Give the rename error `Typography` `data-id="receive-database-rename-error"`.
    `bun run compile` passes.

5. **Replicate gets a Name field, checked the same way.** In `packages/user-interface/src/lib/replicate-form.ts`:
    - Add `destName: string` (the name the replica's database record gets) and `destNameEdited: boolean` (whether the user has typed in the Name field, after which the name stops following the path) to `IReplicateFormState`, each with a comment. `emptyReplicateFormState` sets `''` and `false`.
    - Add `replicaNameFromPath(destPath: string): string`, returning the last non-empty segment after splitting the trimmed path on `/` and `\`, or the trimmed path when it has no separator, with a comment saying it is the name the replica is offered.
    - Add `applyDestPathChange(previous, destPath)`: sets `destPath` and when `destNameEdited` is false also sets `destName` to `replicaNameFromPath(destPath)`. Add `applyDestNameChange(previous, destName)`: sets `destName` and `destNameEdited: true`. `applyDestinationTypeChange` also clears `destName` when it clears the path and `destNameEdited` is false.
    In `replicate-database-dialog.tsx`:
    - Route the path input's `onChange`, the Browse callback and the S3 browser's `onSelect` through `applyDestPathChange`.
    - Below the path field, add `FormControl error={nameError !== undefined}` with `FormLabel` `Name`, an `Input` `data-id="replicate-dest-name-input"` bound through `applyDestNameChange` (clearing `nameError`) and the message in `Typography` `data-id="replicate-dest-name-error"`, with `nameError` state and a comment.
    - At the top of `handleStart`, before `setStep("running")`, run `checkDatabaseName(form.destName, await platform.getDatabases(), undefined)`; on a message set `nameError` and return. Put `destName: nameCheck.trimmedName` in `taskData`.
    - Change the success `Alert` to `Replication completed. "<destName>" has been added to your databases at <destPath>.`.
    Add `destName?: string` to `IReplicateDatabaseData` in `packages/api/src/lib/replicate-database.types.ts`, with a comment saying it is the name the main process gives the replica's database record when the task ends and the handler does not read it. Add the same field as `destName: ?[]const u8 = null` with the same comment to `packages-zig/api-zig/src/lib/replicate-database.types.zig` so the two stay mirrored. Add the tests in Unit Tests to `packages/user-interface/src/test/lib/replicate-form.test.ts`. `bun run compile` and `bun run test -- replicate-form` pass.

6. **The main process names the replica as asked and says so when it cannot.** In `packages-zig/photosphere-core/src/lib/main-process.zig`:
    - Add `destName: ?[]const u8 = null` to `IReplicateInputs`, with a comment.
    - In `handleReplicateSucceeded`, name the record `inputs.destName orelse node_utils.path.basename(inputs.destPath)`.
    - In `handleTaskEnd`'s `replicate-database` block, in the `catch` of `handleReplicateSucceeded`, after `log.exception`, send a notification with color `danger`, duration `8000` and message `The replica at "<destPath>" was made but could not be added to your databases: <message>`, where the message is the text of the error that was thrown (read it the way the other handlers in this file turn a thrown error into text).
    Add the tests in Unit Tests to `packages-zig/photosphere-core/src/test/main-process.test.zig`. Run `bun run test:zig` and watch it pass.

7. **Add smoke scenario `apps/photosphere-smoke-tests/69-database-name-checks/test.sh`.** Header comment saying it drives the name check in Create, Add, Edit and Replicate. It runs on every platform:
    - Before launch: `"${PLATFORM}_reset_app_state"`. `create_database "$TMP_DIR/photos-db" "$REPO_DIR/test/test.png"` and `create_database "$TMP_DIR/other-db"`, seeded as `photos-db` and `other-db`. `"${PLATFORM}_seed_databases_config"` with `[{name: "Photos", path: <app path of photos-db>}, {name: "Other", path: <app path of other-db>}]`.
    - A user types the replica's path: on `android|ios` the short name `photos-copy`, on a desktop `$TMP_DIR/photos-copy`.
    - Create: `click_sidebar_item "$APP_PORT" new-database`, wait for `Create database dialog opened`, type `photos` into `database-name-input` and any path into `database-path-input`, click `create-database-confirm`, `wait_for_value "$APP_PORT" database-name-error 'A database named "photos" already exists.'`. Type an empty string into `database-name-input`, click `create-database-confirm`, `wait_for_value "$APP_PORT" database-name-error "Enter a name."`. Click `create-database-cancel`.
    - Add: open it the way `25-s3-database/test.sh` does per platform (`page-actions-menu` then `add-database-button` on a phone, the databases page's `add-database-button` on a desktop; read the databases page for the desktop button's data-id), type `OTHER` and any path, click `add-database-confirm`, `wait_for_value "$APP_PORT" database-name-error 'A database named "OTHER" already exists.'`. Click `add-database-cancel`.
    - Edit: `click_database_row_action "$APP_PORT" 1 edit-database-button`, wait for `Edit database dialog opened`, type `PHOTOS` into `edit-database-name-input`, click `save-database-button`, `wait_for_value "$APP_PORT" edit-database-name-error "already exists"`. Type `other`, click `save-database-button`, `wait_for_log "$TMP_DIR" "Database entry updated"`, `wait_for_value "$APP_PORT" database-row-name-other "other"`.
    - Replicate: `click_database_row_action "$APP_PORT" 0 replicate-database-button`, wait for `Replicate database dialog opened`, type the replica path into `replicate-dest-path-input`, `wait_for_value "$APP_PORT" replicate-dest-name-input "photos-copy"`. Type `Photos` into `replicate-dest-name-input`, click `replicate-start-button`, `wait_for_value "$APP_PORT" replicate-dest-name-error "already exists"`. Type `Replica`, click `replicate-start-button`, `wait_for_log "$TMP_DIR" "Replication completed for"`, click `replicate-close-button`, `wait_for_value "$APP_PORT" database-row-name-Replica "Replica"`.
    - `check_no_errors "$TMP_DIR"`, `stop_app`, `log_success "Test 69 passed: database-name-checks"`.
    Read `packages/user-interface/src/lib/test-driver.ts` `doType` before relying on typing an empty string to clear a field; it sets the value and fires `input` and `change`, which is what clears it. Run `PHOTOSPHERE_SMOKE_SCENARIO=69 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=69 bun run test:ziggy:and` and watch both pass.

8. **Cover Receive's empty name in the receive scenario.** In `apps/photosphere-smoke-tests/41-receive-database/test.sh`, after `wait_for_log "$TMP_DIR" "Database review step"`, type an empty string into `receive-database-name-input`, click `receive-database-save-button`, `wait_for_value "$APP_PORT" receive-database-name-error "Enter a name."`, then type `received-db` back into it before the existing Save click. Run `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` and watch both pass.

9. **Run the scenarios that drive these dialogs already** and watch each pass on host and Android: `2-create-database`, `6-add-database-entry`, `15-duplicate-name`, `17-replicate-database`, `22-edit-database-origin`, `27-s3-replicate`, `45-s3-share-replica-sync` and `47-create-database-no-collision`. `17` waits for `Replication completed for`, which is still logged with the path's last segment.

10. **Update the documentation to match the code.**
    - `docs/database-names-and-paths.md`, "The name": matching ignores the case of A to Z only and every dialog checks the name before saving, showing `Enter a name.` for an empty one and `A database named "X" already exists.` for a taken one under the Name field. "Database records the app adds": a replication's record takes the name from the Replicate dialog's Name field, which starts as the destination path's last segment and a name taken by the time the replication ends is reported in a notification. Drop the count from "In four cases".
    - `docs/database-names-and-paths.md`, "How a user gives a path", Replicate bullet: mention the Name field.
    - `docs/testing/e2e/desktop/replication/replicate-full-copy.md`, `replicate-partial-copy.md` and `docs/testing/e2e/mobile/replication/replicate-to-another-database.md`: add the Name field (`replicate-dest-name-input`) to the steps that fill the dialog and the replica's name to what the Manage Databases list is expected to show.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`, "Replicating a Database": the dialog asks for a name and the destination is added under that name.
    - `packages/user-interface/src/stories/dialogs/replicate-database-dialog.stories.tsx`: no change needed for the new field to render; run `bun run stories:ziggy -- --headless --no-screenshots` and watch it report no failed story.

11. **Clean up.** Remove `findDatabase` from `IPlatform` in `packages/user-interface/src/context/platform-context.tsx` (the member and its comment), from `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` (the `useCallback` and its entry in the returned object) and from `mockPlatform` in `packages/user-interface/src/stories/mocks/index.tsx`. Run `grep -rn "findDatabase" packages/user-interface/src apps/photosphere-frontend/src` and confirm it finds no use. `bun run compile` and `bun run test` exit 0.

## Unit Tests

- `packages/user-interface/src/test/lib/database-name-check.test.ts`, with a description at the top saying it checks the one rule every dialog uses for a database name:
    - An empty name and a name of only spaces give `empty` and `Enter a name.`.
    - A name that matches another record in a different case of A to Z gives `taken`, the core's sentence with the trimmed name and that record in `takenBy`.
    - Surrounding spaces are trimmed before matching and in `trimmedName`.
    - A record whose name matches `ownName` in any A to Z case is not counted, so renaming to yourself or changing only its case is allowed.
    - Two names that differ only in the case of a non-ASCII letter (`Émile` and `émile`) do not match, as in the core.
    - A name no record holds gives no problem.
- `packages/user-interface/src/test/lib/replicate-form.test.ts`, new tests beside the existing ones:
    - `replicaNameFromPath` gives the last segment of `/a/b/c`, `C:\a\b`, `s3:bucket/prefix/replica/` and `photos-copy`.
    - `applyDestPathChange` makes the name follow the path until `applyDestNameChange` has been called and leaves it alone after.
    - Changing the destination type clears a name that was following the path and keeps one the user typed.
- `packages-zig/photosphere-core/src/test/main-process.test.zig`:
    - "a replication names its record with the name it was given": end a succeeded `replicate-database` task whose input carries `"destName":"Holiday copy"` and find the record by that name with the destination path.
    - "a replication whose name is taken by the time it ends tells the user": add a record named `copy` first, end a succeeded task for `/replicas/copy` with no `destName` and wait for the danger notification naming `/replicas/copy`.
    - The existing tests without `destName` keep passing, because the record falls back to the path's last segment.
- No unit tests for the dialogs: they are React components. Steps 7 and 8 cover them.

## Smoke Tests

- `apps/photosphere-smoke-tests/69-database-name-checks` (new), host and Android: taken names in a different case are refused in Create, Add and Edit with the message under the Name field; an empty name gives `Enter a name.`; Edit can change only the case of its own name; Replicate offers the path's last segment as the name, refuses a taken one and registers the replica under the name typed.
- `apps/photosphere-smoke-tests/41-receive-database`, host and Android: an empty name on the review step gives `Enter a name.` and the import then succeeds.
- The existing scenarios in step 9, host and Android.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `bun run test:zig` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=69 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=69 bun run test:ziggy:and` exit 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` exit 0.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- Decided: one empty-name behaviour, the one Create, Add and Edit already had. The confirm button stays enabled and pressing it shows `Enter a name.` under the Name field. Disabling the button for an empty name was rejected because the button would then need its own explanation beside it while the Name field shows no message. A typed-then-cleared name would leave the user with a dead button. Receive moves to this behaviour.
- The message text changes from `Name is required` to `Enter a name.`, a sentence with a full stop, as text the code displays must be. No smoke test matches the old text. The only doc that does is `docs/testing/e2e/CHECKLIST-NOTES.md`, a record of a past test run, which stays as written.
- The check takes the list from `platform.getDatabases()` at the moment of the press rather than from `useApp().dbs`, so a record added by a background task a moment earlier is seen, which is why Create, Add and Receive asked the core before.
- After this change no frontend code calls `platform.findDatabase`, so the Clean up step removes it from the platform interface, the Ziggy provider and the story mocks. The core's `find-database` message stays: it is part of the app's message set in `apps/photosphere/core/src/app.zig` and has its own tests in `packages-zig/photosphere-core/src/test/databases.test.zig`.
- Matching folds A to Z only, to agree with the core's `std.ascii.eqlIgnoreCase`. The core is the authority because it is what refuses a duplicate when the record is written.
- Receive's db-name-conflict step (Replace or Rename) stays: a received database arriving with a taken name is Receive's own case and its choices are deliberate. Only the detection moves to the shared check.
- The replica's name follows the path until the user types in the Name field, so the existing scenarios that never touch the field still get the path's last segment and keep passing.
- `destName` is optional in the task data and falls back to the path's last segment in the main process, because the existing tests of the replicate wrapper (`packages/node-api/src/test/lib/replicate-database.test.ts`) and of the main process queue the task without it and a record named after the path is still a usable record.
