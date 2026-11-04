# Cancelling Add Database from Open Database keeps Open Database open

## Overview

The Open Database dialog has an **Add database** button that opens the Add Database dialog over it. When the user cancels that nested dialog, Open Database closes too, so the user loses the list they were choosing from. The cause is that `AddDatabaseModal` reports every close the same way and `OpenDatabaseModal` closes itself on any close. This plan makes Add Database report whether it added a database (`onClose(added: boolean)`) and Open Database closes only when it did. Every other caller ignores the argument and keeps its behaviour.

## Issues

- `packages/user-interface/src/components/open-database-modal.tsx` lines 198 to 204: the nested `AddDatabaseModal`'s `onClose` calls `setAddModalOpen(false)` and then `onClose()`, whatever the reason for the close.
- `packages/user-interface/src/components/add-database-modal.tsx`: `onClose: () => void` (line 28) is called from the Cancel button (line 288), from the dialog's own dismiss (Escape or a click outside, through `ResponsiveDialog`'s `onClose` at line 214) and after a successful add (line 156), with no way to tell them apart.

## Steps

1. **Report success or cancel from Add Database.** In `packages/user-interface/src/components/add-database-modal.tsx`:
    - Change `IAddDatabaseModalProps.onClose` to `onClose: (added: boolean) => void;` and its comment to: called when the modal should close, with `true` after a database was added and opened and `false` when the user cancelled or dismissed it.
    - At the end of `handleAdd` (line 156), call `onClose(true)`.
    - Pass `onClose={() => onClose(false)}` to `ResponsiveDialog` (line 214). Passing `onClose` directly is wrong now: Joy's Modal and Drawer call it with the event as the first argument, which is truthy.
    - Change the Cancel button (line 288) to `onClick={() => onClose(false)}`, for the same reason: `onClick={onClose}` would pass the click event as `added`.
    - Run `bun run compile` and see it exit 0.

2. **Close Open Database only on success.** In `packages/user-interface/src/components/open-database-modal.tsx`, replace the nested `AddDatabaseModal`'s `onClose` (lines 200 to 203) with a function of `added` that calls `setAddModalOpen(false)` and then, inside an `if (added) {` block, `onClose()`. Add a comment above it saying a cancelled add returns the user to this list and a database that was added is already open, so this dialog has no more to do. Run `bun run compile` and see it exit 0.

3. **Check the other callers.** The remaining callers pass `() => ...` handlers, which TypeScript accepts for `(added: boolean) => void` and which ignore the argument: `packages/user-interface/src/main.tsx` (line 467), `packages/user-interface/src/components/no-database-loaded.tsx` (line 170), `packages/user-interface/src/pages/databases/databases-page.tsx` (line 410) and `packages/user-interface/src/stories/modals/add-database-modal.stories.tsx` (line 17, through `StoryModalLauncher`'s `onClose: () => void`). Leave them unchanged; step 1's `bun run compile` is the check that they still type-check.

4. **Cover it with a smoke check.** In `apps/photosphere-smoke-tests/3-open-database/test.sh`, between `wait_for_log "$TMP_DIR" "Open database dialog opened"` and the click on `database-list-item-0`, add:
    - A comment saying the user first opens Add Database from this dialog and cancels it, which has to return them to the list rather than close it and that the open below is what proves the list is still there.
    - `send_command "$APP_PORT" click '{"dataId":"open-database-modal-add-database"}' || exit 1`
    - `wait_for_log "$TMP_DIR" "Add database dialog opened"`
    - `send_command "$APP_PORT" click '{"dataId":"add-database-cancel"}' || exit 1`
    - `wait_for_value_gone "$APP_PORT" add-database-confirm "Add" || exit 1`
    - `wait_for_value "$APP_PORT" database-list-item-0 "$DB_NAME"`
    - The existing click on `database-list-item-0` and the waits for "Opening database:" and "Database opened" follow unchanged. Before this change Open Database has closed by then, the click finds no list item and the wait for "Opening database:" times out.
    - Extend the comment at the top of the file with one sentence saying the scenario first opens Add Database from the dialog and cancels it.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=3 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=3 bun run test:ziggy:and` and see both exit 0.

5. **Update the documentation.** In `docs/testing/e2e/desktop/database/open-existing-database.md`, step 1.2, add one sentence after the **Add database** (`open-database-modal-add-database`) instruction: cancelling Add Database (`add-database-cancel`) returns to the Open Database list and adding a database closes both dialogs and opens it.

## Unit Tests

- None. Both changes are to React components, which this repository does not unit test and neither holds logic beyond passing a boolean. The smoke check in step 4 covers the behaviour.

## Smoke Tests

- `apps/photosphere-smoke-tests/3-open-database`: opening Add Database from Open Database and cancelling it leaves the Open Database list on screen and the database in it can still be opened.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=3 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=3 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- A boolean argument was chosen over a second callback (`onAdded`) because every caller already has an `onClose` and only one needs to tell the cases apart.
- On a desktop the dialogs are Joy `Modal`s, which unmount their content as soon as they close, so the check is exact. On a phone they are Joy `Drawer`s, which close with a slide. Under the old code both drawers start closing on the same click and use the same transition, so by the time `wait_for_value_gone` sees Add Database's confirm hidden, Open Database's list is hidden too and the click on `database-list-item-0` finds no visible element (`waitForElement` in `packages/user-interface/src/lib/test-driver.ts` gives up when its timeout runs out and the click has no effect).
- Cancelling Add Database logs no error, so `check_no_errors` needs no ignore pattern.
