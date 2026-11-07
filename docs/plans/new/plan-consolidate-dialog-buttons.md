# Consolidate dialog: its data-id, its button order and its Close label

## Overview

Three faults in `packages/user-interface/src/components/consolidate-database-dialog.tsx`:

- The dialog passes `data-id="consolidate-database-dialog"` to `ResponsiveDialog`, whose prop is `dataId`. JSX accepts any `data-*` attribute on a component without a type error and `ResponsiveDialog` never reads it, so the id never reaches the page.
- The actions put the confirm button before **Cancel** in the source, the reverse of every other dialog in `packages/user-interface/src/components` (Create, Add, Edit, Receive, Share, Replicate and the rest put Cancel first).
- Once the run has ended the close button reads **Done** after a success and **Cancel** after an error. There is no run left to cancel at that point, so both read **Close**, as the Receive and Share dialogs do on their last step.

## Issues

- Line 118: `data-id="consolidate-database-dialog"` on `ResponsiveDialog`.
- Lines 165 to 178: the confirm `Button` (`consolidate-database-confirm`) comes before the close `Button` (`consolidate-database-close`).
- Line 177: `{step === "success" ? 'Done' : 'Cancel'}`.

## Steps

1. **Pass the id through the prop.** In `packages/user-interface/src/components/consolidate-database-dialog.tsx`, change line 118 to `dataId="consolidate-database-dialog"`. Run `bun run compile` and see it exit 0.

2. **Put Cancel first and say Close once the run has ended.** In the same file, inside `DialogActions`:
    - Move the close `Button` (`variant="plain" data-id="consolidate-database-close" onClick={close}`) above the `{step === "configure" && <Button data-id="consolidate-database-confirm" ...>}` block. Keep `data-id="consolidate-database-close"` exactly as it is.
    - Change its label to `{step === "success" || step === "error" ? 'Close' : 'Cancel'}`, with a comment saying the run has ended on those two steps, so there is no run left to cancel.
    - Run `bun run compile` and see it exit 0.

3. **Check the smoke test still drives it.** `apps/photosphere-smoke-tests/36-consolidate-database/test.sh` clicks `consolidate-database-confirm` and `consolidate-database-close` by `data-id` and reads `consolidate-database-success`. None of them changes, so the scenario keeps working. Extend it so it exercises all three fixes:
    - After `wait_for_log "$TMP_DIR" "Consolidate into remote dialog opened"`, add `wait_for_value "$APP_PORT" consolidate-database-dialog "Consolidate into remote"`, with a comment saying this reads the dialog by its own id, which only reaches the page through `ResponsiveDialog`'s `dataId` prop.
    - After the existing `wait_for_value "$APP_PORT" "consolidate-database-success" "Photos uploaded: 1"`, add `wait_for_value "$APP_PORT" consolidate-database-close "Close"`.
    - After the existing click on `consolidate-database-close`, add `wait_for_value_gone "$APP_PORT" consolidate-database-dialog "Consolidate into remote" || exit 1`, so the scenario knows the dialog closed before it reads the databases.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy:and` and see both exit 0.

4. **Documentation.** Read `docs/automatic-photo-backup.md` and `docs/syncing.md`, which describe scenario 36 in their test tables and confirm their rows still describe what it covers; edit a row only if it no longer does. See Notes for why no other document changes.

## Unit Tests

- None. Every change is to a React component, which this repository does not unit test and the dialog's decisions are labels and order. Step 3 covers them.

## Smoke Tests

- `apps/photosphere-smoke-tests/36-consolidate-database`: the dialog is found by `consolidate-database-dialog` once it opens, the close button reads **Close** after a successful run and the dialog is gone after it is clicked. Before this change the first wait times out because the id never reaches the page.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=36 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- Joy's `DialogActions` lays its children out with `orientation="horizontal-reverse"` by default (`node_modules/@mui/joy/DialogActions/DialogActions.js`), so the first child in the source sits at the far right on screen. Putting Cancel first is about matching the source order every other dialog here uses, so the dialogs look alike on screen; it does not mean Cancel appears on the left.
- The button keeps reading **Cancel** while the run is in progress (`step === "running"`), as it does today. Clicking it there closes the dialog; the run itself is not stopped and changing that is outside this plan.
- `consolidate-database-dialog` is placed on the Joy `ModalDialog` on a desktop and on the `Drawer` root on a phone (`packages/user-interface/src/components/responsive-dialog.tsx`) and both contain the title, so the `wait_for_value` on the title text works on both.
- The database summary view also mounts `ConsolidateDatabaseDialog` (`packages/user-interface/src/components/database-summary-view.tsx`), only when its button is clicked. It gets the same fixes from the same component and scenario 36 does not open it.
- The only documents that describe this dialog are the test tables in `docs/automatic-photo-backup.md` and `docs/syncing.md`, which name the scenario and what it proves, not the buttons. The manual e2e docs under `docs/testing/e2e` cover consolidation only through the CLI (`docs/testing/e2e/cli/origin/`), so there is no manual step that names these buttons.
