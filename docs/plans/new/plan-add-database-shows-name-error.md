# Show the name error in the Add Database dialog

## Overview

The Add Database dialog (`packages/user-interface/src/components/add-database-modal.tsx`) validates the name in `handleAdd` and sets `nameError` when the name is empty or already used, but the Name field never renders it. The user clicks **Add**, the dialog stays open and the screen gives no reason. The New Database dialog (`create-database-modal.tsx`, lines 222 to 237) already renders the same state: the `FormControl` takes `error={nameError !== undefined}`, a danger `Typography` under the input shows the message and typing in the field clears it. This plan gives the Add dialog the same display and covers it with a smoke check.

## Issues

- `add-database-modal.tsx` lines 221 to 228: the Name `FormControl` has no `error` prop, the error text is not rendered and the input's `onChange` does not clear `nameError`. `nameError` is set at lines 139 and 144 and cleared on open at line 111 and is never read anywhere else.

## Steps

1. **Render the error under the Name field.** In `packages/user-interface/src/components/add-database-modal.tsx`, replace the Name `FormControl` (currently lines 221 to 228) so it matches Create's:
    - Add `error={nameError !== undefined}` to the `FormControl`.
    - Change the `Input`'s `onChange` to a block that calls `setForm(prev => ({ ...prev, name: event.target.value }))` and then `setNameError(undefined)`, each on its own line.
    - After the `Input`, add `{nameError && (<Typography data-id="database-name-error" level="body-sm" color="danger" sx={{ mt: 0.5 }}>{nameError}</Typography>)}`, laid out over several lines exactly as Create's block at lines 232 to 236, with the extra `data-id` so the smoke test can read the text.
    - `Typography` is already imported in this file. Keep the file's existing indentation for that block (it is one level deeper than Create's).
    - Run `bun run compile` and see it exit 0.

2. **Cover it with a smoke check.** In `apps/photosphere-smoke-tests/6-add-database-entry/test.sh`, after the `case "$PLATFORM"` block that reads the entry back and before `check_no_errors "$TMP_DIR"`, add a section that tries to add a second entry with the same name:
    - Add a comment saying the second add uses a name already in the list, so the dialog has to say why it refuses.
    - `send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1` and `wait_for_log "$TMP_DIR" "Databases page loaded"`.
    - On `android|ios`, first wait for the open that the first add started to settle, exactly as `22-edit-database-origin/test.sh` does after its add: `wait_for_value "$APP_PORT" database-photo-count "photos"`, `wait_for_log "$TMP_DIR" "Database opened"`, `wait_for_log "$TMP_DIR" "Databases page loaded"`, then `send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1`. Copy the comment from scenario 22 that says why.
    - `send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1` and `wait_for_log "$TMP_DIR" "Add database dialog opened"`.
    - Type `$ENTRY_NAME` into `database-name-input` and `$DATABASE_PATH` into `database-path-input` with the same `jq -cn` form the scenario already uses, then click `add-database-confirm`.
    - `wait_for_value "$APP_PORT" database-name-error "already exists"`.
    - Type `"$ENTRY_NAME-2"` into `database-name-input`, then `wait_for_value_gone "$APP_PORT" database-name-error "already exists" || exit 1`, which proves typing clears the error.
    - `send_command "$APP_PORT" click '{"dataId":"add-database-cancel"}' || exit 1`.
    - `log_success "A name already in use is reported under the Name field"`.
    - Extend the comment at the top of the file with one sentence saying the scenario then tries the same name again and expects the error under the Name field.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy:and` and see both exit 0.

3. **Update the documentation.** In `docs/testing/e2e/desktop/database/open-existing-database.md`, step 1.3 (the Add Database dialog), add a bullet under **Name** (`database-name-input`) saying a name that is already used shows `A database named "<name>" already exists.` under the field (`database-name-error`) and that typing in the field clears it. In `docs/database-names-and-paths.md`, section "In the app", extend the "Add database" bullet with one sentence: the name must be filled in and not already used and the reason is shown under the Name field.

## Unit Tests

- None. The change is to a React component, which this repository does not unit test and the validation itself (`handleAdd`) is unchanged. The smoke check in step 2 covers the display.

## Smoke Tests

- `apps/photosphere-smoke-tests/6-add-database-entry`: adding a second entry with the name of the first shows `already exists` in `database-name-error` and typing a new name clears it. Before this change the element never exists, so `wait_for_value` times out and the scenario fails.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- The confirm button is left as it is (`disabled={!form.path}`). Create also disables its confirm while `nameError` is set; the Add dialog re-runs the check on each click, so a second click with the same name shows the same error again. Matching Create's disabled condition is a separate change and is not part of this plan.
- The `data-id` is added to the Add dialog's error text only. Create's error text has no `data-id` and no test reads it.
- `handleAdd` returns before any write when the name collides, so the duplicate attempt logs no error and `check_no_errors` needs no ignore pattern.
- On a phone the dialog is a Joy `Drawer`, which keeps its content mounted while closed. The smoke helpers read only visible elements (`visibleElements` in `packages/user-interface/src/lib/test-driver.ts`), so the other mounted copies of `AddDatabaseModal` (in `main.tsx` and `no-database-loaded.tsx`) do not answer for `database-name-error`.
