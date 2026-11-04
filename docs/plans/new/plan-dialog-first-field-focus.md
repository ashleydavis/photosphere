# Focus the first field when a database dialog opens

## Overview

New Database, Add Database, Edit Database and Receive Database open with no field focused, so a keyboard user has to click or tab into the form before typing. This plan puts React's `autoFocus` on the first input of each: Name in the first three and the pairing code in Receive. The repository already uses `autoFocus` on Joy inputs in `packages/user-interface/src/components/navbar.tsx` and `packages/user-interface/src/pages/gallery/components/asset-info.tsx`.

## Issues

- `packages/user-interface/src/components/create-database-modal.tsx` line 224: the Name `Input` (`database-name-input`) has no `autoFocus`.
- `packages/user-interface/src/components/add-database-modal.tsx` line 223: the Name `Input` (`database-name-input`) has no `autoFocus`.
- `packages/user-interface/src/components/edit-database-modal.tsx` line 237: the Name `Input` (`edit-database-name-input`) has no `autoFocus`.
- `packages/user-interface/src/components/receive-database-dialog.tsx` line 450: the code `Input` (`receive-database-code-input`) has no `autoFocus`.

## Steps

1. **Add `autoFocus` to the four inputs.** In each file above, add `autoFocus` on its own line directly under the input's `data-id` prop. Joy's `Input` passes `autoFocus` to the `<input>` it renders. Run `bun run compile` and see it exit 0.

2. **Run the scenarios that drive these dialogs.** Each one opens the dialog, types into the focused field by `data-id` and confirms, so each proves the dialog still opens, accepts input and confirms with the focus in place, on a desktop and on a phone:
    - `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy:and` (New Database).
    - `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy:and` (Add Database).
    - `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy:and` (Edit Database).
    - `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` (Receive Database).
    - Every run exits 0.

3. **Documentation.** No document describes where focus lands in these dialogs; see Notes. Read `docs/testing/e2e/desktop/database/open-existing-database.md` step 1.3, `docs/testing/e2e/desktop/database/edit-database-origin.md` step 1 and `docs/testing/e2e/desktop/lan-share/share-database.md` step 3 and confirm each still reads correctly with the field focused on open (each tells the user to enter text into a named field, which stays true).

## Unit Tests

- None. `autoFocus` is a prop on React components, which this repository does not unit test.

## Smoke Tests

- `apps/photosphere-smoke-tests/2-create-database`, `6-add-database-entry`, `22-edit-database-origin` and `41-receive-database`, unchanged, run on the host and on Android: the four dialogs still open, take typed input and confirm with `autoFocus` on their first field.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy:and` exit 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=6 bun run test:ziggy:and` exit 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=22 bun run test:ziggy:and` exit 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` exit 0.
- `bun run tev` exits 0.

## Notes

- No smoke check asserts where focus is. The test driver (`packages/user-interface/src/lib/test-driver.ts`) reads values and text by `data-id` and has no command that reports the focused element or sends a key and the Ziggy test transport adds none (`apps/photosphere-frontend/src/lib/ziggy-test-transport.ts`). A new driver command that exists only so a test can read focus is test-only scaffolding in shipped app code, which `CLAUDE.md` allows only with the human's approval, so this plan adds none. The scenarios in step 2 cover what `autoFocus` could break.
- On a desktop `ResponsiveDialog` renders a Joy `Modal`, which renders no content while closed (`node_modules/@mui/joy/Modal/Modal.js`: `if (!keepMounted && !open) return null`), so the input mounts when the dialog opens and React focuses it then. The Modal's `FocusTrap` moves focus to the dialog only when focus is not already inside it (`node_modules/@mui/base/FocusTrap/FocusTrap.js`), so it leaves the input focused.
- On a phone `ResponsiveDialog` renders a Joy `Drawer`, which has no `keepMounted` and always renders its children (`node_modules/@mui/joy/Drawer/Drawer.js`). The dialogs that are always mounted (New Database and Add Database in `main.tsx`, `no-database-loaded.tsx` and `databases-page.tsx`; Edit and Receive in `databases-page.tsx`) therefore mount their inputs with the page, while the sheet is closed and React's mount-time focus runs then rather than when the sheet opens. On a phone this change leaves the opening focus where the drawer's `FocusTrap` puts it, which also keeps the soft keyboard from covering the sheet as it slides up. Focusing on open on a phone would take an effect keyed on `open` with a ref, which is a different change from the one asked for.
- Receive's code input is rendered only on the `enter-code` step, which is the step the dialog opens on.
