# Receive Database checks the trimmed name and path before saving

## Overview

The review step of the Receive Database dialog enables **Save** and the Enter confirm when the name and path are not empty strings, but checks the raw text. A name or path made only of spaces passes the check and the import then runs with the trimmed value: `proceedAfterSecretConflicts` and `handleDbNameConflictResolved` pass `editedName.trim()` and `doImport` stores `editedPath.trim()`, so the database entry is created with an empty name or path. This plan checks the trimmed values, so the confirm stays disabled until both hold text.

## Issues

- `packages/user-interface/src/components/receive-database-dialog.tsx` line 429: `|| (step === "review" && (!editedName || !editedPath))` feeds `dialogConfirmDisabled`, which the Enter handler at line 439 uses.
- Same file, line 638: the **Save** button (`receive-database-save-button`) has `disabled={!editedName || !editedPath}`.
- Lines 264, 314 and 350 trim the values only after the check has let them through.

## Steps

1. **Check the trimmed values.** In `packages/user-interface/src/components/receive-database-dialog.tsx`:
    - Just above the `dialogConfirmDisabled` declaration (line 427), add `const reviewIncomplete = editedName.trim().length === 0 || editedPath.trim().length === 0;` with a comment saying the import stores the trimmed name and path, so a value of only spaces counts as empty here.
    - Change line 429 to `|| (step === "review" && reviewIncomplete)`.
    - Change the Save button's `disabled` (line 638) to `disabled={reviewIncomplete}`.
    - Run `bun run compile` and see it exit 0.

2. **Cover it with a smoke check.** In `apps/photosphere-smoke-tests/41-receive-database/test.sh`, after `wait_for_log "$TMP_DIR" "Database review step"` and before the existing click on `receive-database-save-button`:
    - A comment saying a name of only spaces has to be refused: Save is disabled, so the click has no effect and the review step stays up.
    - `send_command "$APP_PORT" type '{"dataId":"receive-database-name-input","text":"   "}' || exit 1`
    - `send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1`
    - `send_command "$APP_PORT" type '{"dataId":"receive-database-name-input","text":"received-db"}' || exit 1`
    - `wait_for_value "$APP_PORT" receive-database-name-input "received-db"`
    - The existing click on Save, the wait for "Database imported", the close and `wait_for_value "$APP_PORT" "database-row-name-received-db" "received-db"` follow unchanged. Before this change the first click starts the import with the trimmed, empty name and leaves the review step, so the later type finds no input. The import then either stores an entry with an empty name, and the final wait for the `received-db` row times out, or fails and logs an error that `check_no_errors` reports.
    - Extend the comment at the top of the file with one sentence saying the scenario first tries to save under a name of only spaces and expects the dialog to refuse it.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` and see both exit 0.

3. **Update the documentation.** In `docs/testing/e2e/desktop/lan-share/share-database.md`, step 4, add an Expected bullet before the click: **Save** (`receive-database-save-button`) is disabled while the name (`receive-database-name-input`) or the path (`receive-database-path-input`) is empty or only spaces. In `docs/database-names-and-paths.md`, section "In the app", extend the "Receive" bullet with: Save is disabled until the name and the path are filled in.

## Unit Tests

- None. The change is a derived boolean in a React component, which this repository does not unit test. The Enter path goes through `shouldConfirmOnKey`, whose disabled case `packages/user-interface/src/test/lib/dialog-keys.test.ts` already covers.

## Smoke Tests

- `apps/photosphere-smoke-tests/41-receive-database`: Save with a name of only spaces leaves the review step open and the database is then imported under the name typed afterwards and listed as `received-db`.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- Scenario 41 runs on a desktop and on Android. `require_lan_bridge` in `apps/photosphere-smoke-tests/lib/common.sh` returns at once off Android and on an emulator it checks the LAN bridge the host sender needs.
- The smoke check covers the name. The path uses the same `reviewIncomplete` value, so a second round trip for the path is not added.
- The Enter path is not driven by a smoke check: the test driver has no key command.
- A disabled button ignores the driver's click: `doClick` calls `HTMLElement.click()`, which dispatches no click event on a disabled `<button>`.
