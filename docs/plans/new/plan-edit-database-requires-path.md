# Edit Database refuses to save an empty path

## Overview

The Edit Database dialog lets the user clear the **Path** field and still press **Save** or Enter. `handleSave` then calls `platform.setDatabaseOrigin('', ...)` and `updateDatabase` with an empty path, which either fails in the core or stores a database entry that points nowhere. The New Database and Add Database dialogs already disable their confirm while the path is empty (`disabled={!form.path}` and `createDialogKeyHandler(..., !form.path)`). This plan does the same for Edit, on the trimmed path, so a path of spaces is refused too.

## Issues

- `packages/user-interface/src/components/edit-database-modal.tsx` line 230: `onKeyDown={createDialogKeyHandler(handleSave, false)}` confirms on Enter whatever the form holds.
- Same file, lines 326 to 331: the **Save** button (`save-database-button`) has no `disabled` prop.
- `handleSave` (lines 175 to 221) checks the name but not the path and passes `form.path.trim()` straight to `setDatabaseOrigin` and `updateDatabase` (or `addDatabase` when there is no entry).

## Steps

1. **Disable Save and Enter on an empty path.** In `packages/user-interface/src/components/edit-database-modal.tsx`:
    - Just before the `return (` of `EditDatabaseModal`, add `const pathMissing = form.path.trim().length === 0;` with a comment saying a database entry has to point somewhere, so Save and Enter both wait for a path, as they do in New Database and Add Database and the path is trimmed because `handleSave` stores it trimmed.
    - Change line 230 to `onKeyDown={createDialogKeyHandler(handleSave, pathMissing)}`.
    - Add `disabled={pathMissing}` to the **Save** button (`save-database-button`), on its own line above `onClick`.
    - Run `bun run compile` and see it exit 0.

2. **Cover it with a smoke check.** In `apps/photosphere-smoke-tests/22-edit-database-origin/test.sh`, after `wait_for_log "$TMP_DIR" "Edit database dialog opened"` and the existing type of `$NEW_ORIGIN` into `database-origin-input` and before the existing click on `save-database-button`:
    - Read the path the dialog shows: `wait_for_value "$APP_PORT" edit-database-path-input "test-db"`, then `ORIGINAL_PATH="$(read_value "$APP_PORT" edit-database-path-input)"`. A comment says the path is read back rather than typed again because on a phone the stored path is the one the app resolved, not the short name the user typed.
    - Clear it: `send_command "$APP_PORT" type '{"dataId":"edit-database-path-input","text":""}' || exit 1`, then click `save-database-button`. A comment says Save is disabled with no path, so the click has no effect and the dialog stays open with the origin still typed.
    - Put the path back: type `$ORIGINAL_PATH` into `edit-database-path-input` with `jq -cn` and `wait_for_value "$APP_PORT" edit-database-path-input "$ORIGINAL_PATH"`.
    - The existing click on `save-database-button` and `wait_for_log "$TMP_DIR" "Database entry updated"` follow unchanged.
    - After the existing desktop `config.json` check and before `check_no_errors`, reopen the entry and read it back on every platform: `click_database_row_action "$APP_PORT" 0 edit-database-button || exit 1`, `wait_for_log "$TMP_DIR" "Edit database dialog opened"`, `wait_for_value "$APP_PORT" edit-database-path-input "$ORIGINAL_PATH"`, `wait_for_value "$APP_PORT" database-origin-input "$NEW_ORIGIN"`, then click `edit-database-cancel` and `wait_for_value_gone "$APP_PORT" edit-database-cancel "Cancel" || exit 1`. A comment says that before the fix the click on Save with no path ran `handleSave`: either it stored the entry with an empty path and closed the dialog before the path was typed back, so the path wait fails, or the core refused the empty path and logged a save error that `check_no_errors` reports.
    - Extend the comment at the top of the file with one sentence: the scenario clears the path and expects Save to refuse it, then reopens the entry and checks the path and origin on every platform.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy:and` and see both exit 0.

3. **Update the documentation.** In `docs/testing/e2e/desktop/database/edit-database-origin.md`, step 3, add an Expected bullet: **Save** (`save-database-button`) is disabled while **Path** (`edit-database-path-input`) is empty or only spaces. In `docs/database-names-and-paths.md`, section "In the app", extend the "Edit database" bullet with: Save is disabled until the path is filled in. The sentence above that list ("Each dialog trims the path and checks it is filled in.") is then true of Edit as well and stays as it is.

## Unit Tests

- None for the component: React components are not unit tested here and the change is one derived boolean. The decision that a disabled confirm ignores Enter is `shouldConfirmOnKey` in `packages/user-interface/src/lib/dialog-keys.ts`, which `packages/user-interface/src/test/lib/dialog-keys.test.ts` already covers with a case that passes `confirmDisabled` as `true` and expects `false`. That test is unchanged.

## Smoke Tests

- `apps/photosphere-smoke-tests/22-edit-database-origin`: clicking Save with an empty path leaves the dialog open and after putting the path back and saving, the reopened entry shows the original path and the new origin, on a desktop and on a phone.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- A disabled button ignores the driver's click: `doClick` in `packages/user-interface/src/lib/test-driver.ts` calls `HTMLElement.click()`, which dispatches no click event on a disabled `<button>`.
- The Enter path is not driven by a smoke check: the test driver has no key command. It is covered by the `dialog-keys` unit test and by passing the same `pathMissing` value to both the button and the key handler.
- The trimmed check differs from New Database and Add Database, which test `!form.path`. Those two are not changed by this plan.
- `click_database_row_action` (in `apps/photosphere-smoke-tests/lib/common.sh`) opens the row's menu on a phone and clicks the row's button on a desktop, so the reopen needs no platform `case`.
