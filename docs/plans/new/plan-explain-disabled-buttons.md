# Say why a dialog's confirm button is disabled and apply the S3 and key rules in Create and Add

## Overview

A disabled confirm button with no explanation leaves the user hunting for what is missing. Replicate's "Start replication" is disabled for any of three reasons and says none of them. Create and Add go the other way: they accept an S3 database with no S3 credentials chosen and an encrypted database with no key chosen and the failure comes later, from the core, in a form that does not say what was missed. This plan puts each dialog's confirm rules in one unit-tested `lib/` module, makes Create and Add refuse the same incomplete S3 and encrypted forms that Replicate refuses and shows the first reason as a short line beside the confirm button in every database dialog whose confirm button can be disabled.

## Issues

- `packages/user-interface/src/components/replicate-database-dialog.tsx` `startDisabled` (around lines 88 to 90) is true for an empty destination, a destination equal to the source path, or an S3 destination without credentials. The button gives no reason.
- `packages/user-interface/src/components/create-database-modal.tsx` disables Create only for an empty path (`disabled={!form.path || nameError !== undefined}`, around line 299). `packages/user-interface/src/components/add-database-modal.tsx` disables Add only for an empty path (`disabled={!form.path}`, around line 291). Neither checks `s3Key` for an S3 type or `encryptionKey` when `encrypted` is on.
- `packages/user-interface/src/components/consolidate-database-dialog.tsx` disables Consolidate for an empty remote path and `packages/user-interface/src/components/receive-database-dialog.tsx` disables Start Receiving for a code that is not four digits and Save for an empty name or path, all without a reason.
- Create's Encrypted `Switch` has no data-id (Add's is `database-encrypted-switch`), so a smoke test cannot reach it.

## Steps

1. **Write the rules as plain functions.** Add `packages/user-interface/src/lib/confirm-reasons.ts`, with a comment block at the top saying each function returns the first reason a dialog's confirm button is disabled, or undefined when it is enabled and that the dialog both disables the button and shows the reason from the same value so the two cannot disagree. Export:
    - `IDatabaseFormConfirmInput`, with a commented field each: `storageType: "filesystem" | "s3"`, `s3Key: string | undefined`, `path: string`, `encrypted: boolean`, `encryptionKey: string | undefined`.
    - `databaseFormConfirmReason(input: IDatabaseFormConfirmInput): string | undefined`, for Create and Add. The rules, checked in the order the fields appear in the form from top to bottom: S3 type and no `s3Key` gives `Choose S3 credentials.`; a path that is empty after trimming gives `Enter a path.`; `encrypted` and no `encryptionKey` gives `Choose an encryption key.`.
    - `replicateConfirmReason(form: IReplicateFormState, sourcePath: string): string | undefined`. In form order: S3 destination and no `form.secrets.s3Key` gives `Choose S3 credentials.`; an empty trimmed `destPath` gives `Enter a destination path.`; a trimmed `destPath` equal to `sourcePath` gives `Choose a destination other than the source database.`.
    - `receiveReviewConfirmReason(name: string, path: string): string | undefined`: an empty trimmed name gives `Enter a name.`; an empty trimmed path gives `Enter a path.`. Write it only when `receive-database-save-button` in `receive-database-dialog.tsx` is still disabled by `!editedName || !editedPath`. When its `disabled` is `editedPath.trim().length === 0` alone (an empty name is then reported under the Name field when Save is pressed), leave this function and its tests out; step 4 says what Receive uses instead.
    Write `packages/user-interface/src/test/lib/confirm-reasons.test.ts` (see Unit Tests). Run `bun run test -- confirm-reasons` and watch it pass.

2. **Create and Add use the rules.** In `create-database-modal.tsx` and `add-database-modal.tsx`:
    - Compute `const confirmReason = databaseFormConfirmReason({ ... })` from `form`, written across lines, one property per line.
    - Create's button: `disabled={confirmReason !== undefined || nameError !== undefined}` and the same expression in its `createDialogKeyHandler` call. Add's button and key handler: `disabled={confirmReason !== undefined}`.
    - Render `{confirmReason && <Typography data-id="create-database-confirm-reason" level="body-sm" color="neutral" sx={{ mt: 1, textAlign: 'right' }}>{confirmReason}</Typography>}` as the last child of `DialogContent` in Create and the same with `data-id="add-database-confirm-reason"` in Add.
    - Give Create's Encrypted `Switch` `data-id="database-encrypted-switch"`, the id Add's already has.
    When Create and Add have no Encrypted switch (they choose every secret through a `Configure secrets…` button and `ConfigureSecretsModal`, where choosing a key is what makes a database encrypted), leave `encrypted` and `encryptionKey` out of `IDatabaseFormConfirmInput`, leave the `Choose an encryption key.` rule and its tests out of step 1 and leave out the Encrypted part of step 5. In that case step 5 chooses secrets through the modal the way `27-s3-replicate/test.sh` does. `bun run compile` passes.

3. **Replicate uses the rules.** In `replicate-database-dialog.tsx`, replace `startDisabled` with `const confirmReason = replicateConfirmReason(form, sourceEntry.path);` and `const startDisabled = confirmReason !== undefined;` and render the reason line with `data-id="replicate-confirm-reason"` as the last child of the `configure` step's fragment. `bun run compile` passes.

4. **Consolidate and Receive show their reasons.**
    - `consolidate-database-dialog.tsx`: in the `configure` step, when `remotePath.trim().length === 0`, render the reason line `Enter a remote path.` with `data-id="consolidate-confirm-reason"`. One rule needs no function: the condition already sits on the button.
    - `receive-database-dialog.tsx`: in the `enter-code` step, when the code fails `/^\d{4}$/`, render `Enter the 4-digit pairing code.` with `data-id="receive-database-confirm-reason"`. In the `review` step, when `receiveReviewConfirmReason` was written in step 1, replace `!editedName || !editedPath` on `receive-database-save-button` and in `dialogConfirmDisabled` with `receiveReviewConfirmReason(editedName, editedPath) !== undefined` and render that reason with the same data-id. When it was left out, render `Enter a path.` with the same data-id whenever `editedPath.trim().length === 0`, the condition already on the button.
    `bun run compile` passes.

5. **Add smoke scenario `apps/photosphere-smoke-tests/71-disabled-button-reasons/test.sh`.** Header comment saying it checks that each disabled confirm button says why and that Create and Add refuse S3 without credentials and encryption without a key. It runs on every platform:
    - Before launch: `"${PLATFORM}_reset_app_state"`, `create_database "$TMP_DIR/src-db"` seeded as `src-db` and `"${PLATFORM}_seed_databases_config"` with `[{name: "Source", path: "src-db"}]`. A simple name resolves to `<data dir>/dbs/src-db`, the folder `${PLATFORM}_seed_database` writes (see "Simple names and the data directory" in `docs/database-names-and-paths.md`), so the record's path is exactly what a user types on every platform.
    - `start_app`, `wait_for_ready`. On the secrets page add an S3 secret with `add_secret_via_ui "$APP_PORT" "reason-s3" "s3-credentials" "us-east-1"` and an encryption key with `add_secret_via_ui "$APP_PORT" "reason-key" "encryption-key" ""`.
    - Create: `click_sidebar_item "$APP_PORT" new-database`, wait for `Create database dialog opened`. `wait_for_value "$APP_PORT" create-database-confirm-reason "Enter a path."`. Type `reason-db` into `database-path-input`; `wait_for_value_gone "$APP_PORT" create-database-confirm-reason "Enter a path." || exit 1`. Click `database-encrypted-switch`; `wait_for_value "$APP_PORT" create-database-confirm-reason "Choose an encryption key."`. Choose `reason-key` with `select-encryption-button` and the secret modal, as `25-s3-database/test.sh` chooses an S3 secret with `select-s3-button`; `wait_for_value_gone "$APP_PORT" create-database-confirm-reason "Choose an encryption key." || exit 1`. Click `database-storage-type-select` then `database-storage-type-option-s3`; `wait_for_value "$APP_PORT" create-database-confirm-reason "Choose S3 credentials."`. Click `create-database-cancel`.
    - Add: open it per platform as `25-s3-database/test.sh` does (`page-actions-menu` then `add-database-button` on a phone; on a desktop the databases page's add button, whose data-id is read from `packages/user-interface/src/pages/databases/databases-page.tsx`). Switch to S3, `wait_for_value "$APP_PORT" add-database-confirm-reason "Choose S3 credentials."`, choose `reason-s3` with `select-s3-button`, `wait_for_value "$APP_PORT" add-database-confirm-reason "Enter a path."`. Click `add-database-cancel`.
    - Replicate: navigate to `databases`, `click_database_row_action "$APP_PORT" 0 replicate-database-button`, wait for `Replicate database dialog opened`. `wait_for_value "$APP_PORT" replicate-confirm-reason "Enter a destination path."`. Type `src-db` into `replicate-dest-path-input`; `wait_for_value "$APP_PORT" replicate-confirm-reason "Choose a destination other than the source database."`. Type `src-copy`; `wait_for_value_gone "$APP_PORT" replicate-confirm-reason "Choose a destination" || exit 1`. Click `replicate-cancel-button`.
    - Consolidate: `click_database_row_action "$APP_PORT" 0 consolidate-database-button`, wait for `Consolidate into remote dialog opened`, `wait_for_value "$APP_PORT" consolidate-confirm-reason "Enter a remote path."`, click `consolidate-database-close`.
    - `check_no_errors "$TMP_DIR"`, `stop_app`, `log_success "Test 71 passed: disabled-button-reasons"`.
    Before relying on `wait_for_value_gone` for a reason line that is removed from the page, read it in `apps/photosphere-smoke-tests/lib/common.sh`: it passes when the element reads empty in an answer that says ok, which is what an absent line gives. Run `PHOTOSPHERE_SMOKE_SCENARIO=71 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=71 bun run test:ziggy:and` and watch both pass.

6. **Run the scenarios that fill these dialogs already** and watch each pass on host and Android, because Create and Add now refuse forms they accepted before: `2-create-database`, `6-add-database-entry`, `17-replicate-database`, `25-s3-database`, `26-s3-database-lifecycle`, `27-s3-replicate`, `28-s3-failure`, `36-consolidate-database`, `38-reset-device-s3`, `41-receive-database`, `47-create-database-no-collision` and `52-encrypted-database`. Any of them that creates an S3 or encrypted database without choosing its secret is filling the form in a way a user now cannot; make it choose the secret through the dialog the way `26-s3-database-lifecycle/test.sh` does.

7. **Update the documentation to match the code.**
    - `docs/database-names-and-paths.md`, "How a user gives a path", "In the app": New database and Add database need S3 credentials for an S3 path and a key when Encrypted is on, as Replicate already needs credentials for an S3 destination and each dialog says beside its confirm button what is still missing.
    - `docs/testing/e2e/desktop/database/open-existing-database.md`, `docs/testing/e2e/mobile/database/create-and-open-database.md`, `docs/testing/e2e/mobile/s3/s3-database.md` and `docs/testing/e2e/desktop/replication/replicate-full-copy.md`: wherever a step fills one of these dialogs, add the expected reason line (by its data-id) before the field that clears it.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`, "Adding a Database": S3 credentials are required for an S3 database and a key for an encrypted one and the dialog says which is missing.
    - Stories: the existing `packages/user-interface/src/stories/modals/create-database-modal.stories.tsx`, `add-database-modal.stories.tsx` and `packages/user-interface/src/stories/dialogs/replicate-database-dialog.stories.tsx` open on an empty form and so show the reason line with no change. Run `bun run stories:ziggy -- --headless --no-screenshots` and watch it report no failed story.

## Unit Tests

`packages/user-interface/src/test/lib/confirm-reasons.test.ts`, with a description at the top saying it checks the reason each database dialog gives for a disabled confirm button:

- `databaseFormConfirmReason`: a filled filesystem form gives undefined; an empty path and a path of spaces give `Enter a path.`; S3 with no key gives `Choose S3 credentials.` even when the path is empty (the field above comes first); S3 with a key and a path gives undefined; Encrypted with no key gives `Choose an encryption key.`; Encrypted with a key gives undefined.
- `replicateConfirmReason`: an empty destination gives `Enter a destination path.`; the source path, with and without surrounding spaces, gives `Choose a destination other than the source database.`; an S3 destination with no key gives `Choose S3 credentials.`; a filled form gives undefined.
- `receiveReviewConfirmReason`, when step 1 wrote it: an empty name gives `Enter a name.`; a name and an empty path gives `Enter a path.`; both filled gives undefined.

No unit tests for the dialogs: they are React components. Step 5 covers them.

## Smoke Tests

- `apps/photosphere-smoke-tests/71-disabled-button-reasons` (new), host and Android: Create shows `Enter a path.`, `Choose an encryption key.` and `Choose S3 credentials.` as the form changes and clears each as it is satisfied; Add shows `Choose S3 credentials.` then `Enter a path.`; Replicate shows `Enter a destination path.` and the same-as-source reason and clears it for a different destination; Consolidate shows `Enter a remote path.`.
- The existing scenarios in step 6, host and Android.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=71 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=71 bun run test:ziggy:and` exit 0.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- The reason line goes at the end of the dialog's content, right-aligned above the buttons, rather than inside `DialogActions`, so it sits by the confirm button on a desktop and in a phone's drawer without depending on how Joy lays out the actions row.
- Only the first reason is shown. The rules are ordered as the fields appear, so the reason always points at the topmost field still missing and fixing it reveals the next.
- Create's `nameError !== undefined` term stays on its button. The name error is already shown under the Name field, which is its explanation.
- Edit has no disabled state and is not changed. Its rules are the core's, reported on Save.
- Rejected: a tooltip on the disabled button. A disabled button does not fire the pointer events a tooltip needs in every web view and a phone has no hover.
- The texts are full sentences with a full stop, as text the code displays must be. They name what to do rather than what is wrong.
