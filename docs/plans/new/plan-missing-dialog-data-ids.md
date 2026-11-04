# Add the missing data-ids to the database dialogs

## Overview

The smoke tests and the manual e2e docs find every control by its `data-id`. Five controls in the database dialogs have none, so no test can click them and no manual step can name them:

- The **Encrypted** switch in New Database. Add Database's switch already carries `database-encrypted-switch` and `docs/testing/e2e/desktop/lan-share/share-database.md` already names it.
- **Select this location** in the S3 browser.
- The corner close button (`ModalClose`) of View Database. Edit Database's carries `edit-database-close`.
- **Back** and **Continue** on Receive Database's secret-conflict step. The database-name conflict step's Continue already carries `receive-database-name-conflict-continue`.

This plan adds the ids and smoke checks that click three of them.

## Issues

- `packages/user-interface/src/components/create-database-modal.tsx` lines 283 to 286: the `Switch` has no `data-id`.
- `packages/user-interface/src/components/s3-browser-modal.tsx` lines 192 to 197: the **Select this location** `Button` has no `data-id`.
- `packages/user-interface/src/components/view-database-dialog.tsx` line 94: `<ModalClose />` has no `data-id`.
- `packages/user-interface/src/components/receive-database-dialog.tsx` lines 648 to 654: the **Back** and **Continue** buttons of the `conflict` step have no `data-id`.

## Steps

1. **Add the ids.**
    - `create-database-modal.tsx`: add `data-id="database-encrypted-switch"` as the first prop of the Encrypted `Switch`, as in `add-database-modal.tsx` line 275.
    - `s3-browser-modal.tsx`: add `data-id="s3-browser-select"` as the first prop of the **Select this location** `Button`.
    - `view-database-dialog.tsx`: change `<ModalClose />` to `<ModalClose data-id="view-database-close" />`, as `edit-database-modal.tsx` line 232 does.
    - `receive-database-dialog.tsx`: on the `conflict` step, add `data-id="receive-database-conflict-back"` to the **Back** button and `data-id="receive-database-conflict-continue"` to the **Continue** button.
    - Confirm none of the new ids is used anywhere else with `grep -rn` over `packages` and `apps` (excluding `node_modules`), apart from `database-encrypted-switch` in `add-database-modal.tsx`. Two dialogs sharing that id is safe: the driver reads only visible elements and only one of the two dialogs is open at a time.
    - Run `bun run compile` and see it exit 0.

2. **Click the Encrypted switch in New Database.** In `apps/photosphere-smoke-tests/2-create-database/test.sh`, after the two `type` commands and before the click on `create-database-confirm`:
    - A comment saying the Encrypted switch shows the Encryption Key row and hides it again and the database is still created without encryption.
    - `send_command "$APP_PORT" click '{"dataId":"database-encrypted-switch"}' || exit 1`
    - `wait_for_value "$APP_PORT" select-encryption-button "Select"`
    - `send_command "$APP_PORT" click '{"dataId":"database-encrypted-switch"}' || exit 1`
    - `wait_for_value_gone "$APP_PORT" select-encryption-button "Select" || exit 1`
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy:and` and see both exit 0.

3. **Close View Database by its corner button.** In `apps/photosphere-smoke-tests/10-view-database/test.sh`, after `wait_for_log "$TMP_DIR" "Secret revealed"` and before `check_no_errors`:
    - `send_command "$APP_PORT" click '{"dataId":"view-secret-close-button"}' || exit 1`
    - `wait_for_value_gone "$APP_PORT" view-secret-type "api-key" || exit 1`
    - `send_command "$APP_PORT" click '{"dataId":"view-database-close"}' || exit 1`
    - `wait_for_value_gone "$APP_PORT" view-database-name "My Test DB" || exit 1`
    - Extend the comment at the top of the file with one sentence saying the scenario then closes both dialogs, View Database by its corner close button.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=10 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=10 bun run test:ziggy:and` and see both exit 0.

4. **Pick a location in the S3 browser.** In `apps/photosphere-smoke-tests/25-s3-database/test.sh`, section 1, replace the `close_s3_browser` call that follows `log_success "Seeded directories listed from the bucket root"` with:
    - A comment saying the location is chosen with **Select this location**, which closes the browser and fills the path with the bucket in `s3:<bucket>/<prefix>` form.
    - `send_command "$APP_PORT" click '{"dataId":"s3-browser-select"}' || exit 1`
    - `wait_for_value "$APP_PORT" database-path-input "s3:$S3_EMULATOR_BUCKET/"`
    - Cancel the dialog under it with the same `case "$PLATFORM"` as `close_s3_browser` (`add-database-cancel` on a phone, `create-database-cancel` on a desktop). Factor that `case` into a function `cancel_add_dialog` with a comment and call it from `close_s3_browser` and from here.
    - `log_success "Select this location fills the path with the chosen bucket"`.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` and see both exit 0.

5. **Update the documentation.** Name the new ids where the manual e2e docs describe the controls, in the bracketed `data-id` form those docs use:
    - `docs/testing/e2e/desktop/database/view-database-details.md`, step 2: add a step that closes the dialog with the corner close button (`view-database-close`) and an Expected bullet that the dialog closes.
    - `docs/testing/e2e/desktop/lan-share/share-database.md`: after step 4, add an Agent notes bullet saying that when a received secret already exists in the vault, the dialog shows a conflict step whose buttons are **Back** (`receive-database-conflict-back`) and **Continue** (`receive-database-conflict-continue`).

## Unit Tests

- None. The changes are attributes on React components, which this repository does not unit test.

## Smoke Tests

- `apps/photosphere-smoke-tests/2-create-database`: `database-encrypted-switch` on New Database toggles the Encryption Key row on and off.
- `apps/photosphere-smoke-tests/10-view-database`: `view-database-close` closes View Database.
- `apps/photosphere-smoke-tests/25-s3-database`: `s3-browser-select` closes the browser and fills `database-path-input` with `s3:<bucket>/`.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=2 bun run test:ziggy:and` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=10 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=10 bun run test:ziggy:and` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- A click on a Joy `Switch` by its `data-id` reaches the switch: the id sits on Joy's wrapper `<span>` and `clickTarget` in `packages/user-interface/src/lib/test-driver.ts` redirects a click on a wrapper holding exactly one checkbox to that checkbox.
- Each new smoke check fails without its id: the driver's click waits for the element, gives up when it is not found and clicks no element, so the `wait_for_value` or `wait_for_value_gone` that follows times out.
- The Receive conflict ids are not clicked by a smoke check. Reaching that step needs a secret in the receiving vault with the same name as one the sender carries and scenario 41 is built on a clean vault on purpose ("On a clean slate there is no secret or name conflict"). The ids are there for the manual step in `share-database.md` and for a later scenario.
- `select-encryption-button` is rendered only while Encrypted is on (`create-database-modal.tsx` line 291), which is what the scenario 2 check reads.
- The New Database Encrypted switch and **Select this location** get no manual doc edit. The only manual step that toggles Encrypted is in `share-database.md` and uses Add Database, whose switch already carries the id and no manual e2e step browses S3 for a path (`docs/testing/e2e/mobile/s3/s3-database.md` receives its database over the LAN). `docs/database-names-and-paths.md` describes the S3 browser without naming controls.
- `S3BrowserModal.handleSelectLocation` builds the path as `` `s3:${bucket}/${prefix}` `` and the prefix is empty at the bucket's top, so the field reads `s3:<bucket>/`.
