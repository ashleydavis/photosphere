# One set of labels, one path placeholder and one secrets control across the database dialogs

## Overview

The database dialogs ask for the same things in different words and with different controls. The path field is "Path" in New, Add, Edit and Receive, "Destination path" in Replicate and "Remote path" in Consolidate and only Consolidate shows an example of what to type. Secrets are chosen with three rows of "Select" buttons and an Encrypted switch in New and Add, but with a single "Configure secrets…" button and a modal in Edit and Replicate. Receive's two conflict steps both return to the review step, one with a button called "Back" and the other with one called "Cancel". This plan settles one label for each field, one placeholder for every path field, one way to choose secrets (the Configure secrets modal) and one label for going back and updates the smoke tests, manual tests and stories that read the old text or drive the old controls.

## Issues

- Path labels: `packages/user-interface/src/components/replicate-database-dialog.tsx` "Destination path", `consolidate-database-dialog.tsx` "Remote path", the rest "Path". Replicate also says "Destination type" and "Destination secrets" where the others say "Type" and "Secrets".
- Placeholders: only `consolidate-remote-path-input` has one (`/path/to/backup or s3:bucket/prefix`).
- Secrets: `create-database-modal.tsx` and `add-database-modal.tsx` render `renderSecretButton` rows (`select-s3-button`, `select-encryption-button`, `select-geocoding-button`, `chosen-s3-secret` and friends) through `SelectSecretModal`, plus an Encrypted `Switch`. `edit-database-modal.tsx` and `replicate-database-dialog.tsx` render a summary and `Configure secrets…` through `ConfigureSecretsModal`. Each of the last two has its own copy of the summary function.
- `receive-database-dialog.tsx`: the `conflict` step's return button says `Back`, the `db-name-conflict` step's says `Cancel`, both call `setStep("review")` and neither has a data-id.
- Displayed text with em dashes: Receive's conflict options (`Reuse existing — skip importing this secret`, `Replace existing — may break ...`, `Replace existing — removes the existing entry ...`) and Replicate's Full mode description (`Copies everything — every original, ...`).

## Steps

1. **Shared label text and the secrets summary.** Add `packages/user-interface/src/lib/database-dialog-text.ts`, with a comment block saying it holds the words every database dialog uses for the same field, so they cannot drift apart again. Export, each with a comment:
    - `PATH_LABEL = "Path"`, `PATH_PLACEHOLDER = "Folder path or s3:bucket/prefix"`, `TYPE_LABEL = "Type"`, `SECRETS_LABEL = "Secrets"`, `CONFIGURE_SECRETS_LABEL = "Configure secrets…"`, `BACK_LABEL = "Back"`.
    - `summariseSecrets(selection: IDatabaseSecretsSelection, s3Required: boolean): string`: the selected secrets as `S3: <name>`, `Encryption: <name>` and `Geocoding: <name>` joined with ` · `; with none selected, `S3 credentials required` when `s3Required` and `No secrets configured` otherwise. This is the text Edit's `summariseSecrets` and Replicate's `summariseDestSecrets` produce today.
    Write `packages/user-interface/src/test/lib/database-dialog-text.test.ts` (see Unit Tests). `bun run test -- database-dialog-text` passes.

2. **Labels and placeholder on every path field.** Use `PATH_LABEL` and `placeholder={PATH_PLACEHOLDER}` on the path field of New (`database-path-input`), Add (`database-path-input`), Edit (`edit-database-path-input`), Receive (`receive-database-path-input`), Replicate (`replicate-dest-path-input`) and Consolidate (`consolidate-remote-path-input`). Where a dialog renders its path through a shared `PathField` component, pass them as its `label` and `placeholder`. Use `TYPE_LABEL` for the type selects in New, Add, Replicate and, when it has one, Consolidate. Data-ids stay as they are. `bun run compile` passes.

3. **Edit and Replicate use the shared summary and labels.** Replace Edit's `summariseSecrets` with `summariseSecrets(form, false)` from the new module (pass the three fields as an `IDatabaseSecretsSelection` written across lines) and Replicate's `summariseDestSecrets` with `summariseSecrets(form.secrets, isS3Dest)`. Use `SECRETS_LABEL` and `CONFIGURE_SECRETS_LABEL` for the label and the button in both. `bun run compile` passes.

4. **New and Add choose secrets the same way.** In `create-database-modal.tsx` and `add-database-modal.tsx`:
    - Remove `encrypted` from the form state and `emptyFormState`, the Encrypted `Switch`, `renderSecretButton` and its three calls, `handleSecretSelected`, the `selectSecretType` state, the three `...SecretName` states and the `SelectSecretModal` block and import.
    - Add `const [secretsModalOpen, setSecretsModalOpen] = useState(false);` with a comment and take `secrets` from `useApp()`, filtered by type into S3, encryption and geocoding lists as `packages/user-interface/src/pages/databases/databases-page.tsx` does.
    - Where the S3 Credentials row was, render a `FormControl` with `FormLabel` `SECRETS_LABEL`, a `Typography` summary (`data-id="create-database-secrets-summary"` in New, `"add-database-secrets-summary"` in Add) showing `summariseSecrets(<the three keys>, form.storageType === 's3')` and a `Button` (`data-id="create-database-configure-secrets-button"` / `"add-database-configure-secrets-button"`, `variant="outlined"`, `size="sm"`) labelled `CONFIGURE_SECRETS_LABEL` that opens the modal. Lay it out as Edit's Secrets row is laid out.
    - Render `ConfigureSecretsModal` with `open={secretsModalOpen}`, `initialValue` the form's three keys, the three lists, `fields={form.storageType === 's3' ? ['s3', 'encryption', 'geocoding'] : ['encryption', 'geocoding']}`, `quickCreateDefaultName={form.name || form.path}`, `onSave` writing the three keys into the form and closing and `onClose` closing.
    - Changing the type still clears `s3Key`, as it does today.
    - If the confirm button's disabled state comes from `databaseFormConfirmReason` in `packages/user-interface/src/lib/confirm-reasons.ts` and that function takes `encrypted` and `encryptionKey`, remove those two inputs, their `Choose an encryption key.` rule and its tests from that module, because choosing a key is now what makes the database encrypted.
    `bun run compile` passes.

5. **Consolidate's secrets, when it has them.** If `consolidate-database-dialog.tsx` has a Secrets row, make its label `SECRETS_LABEL`, its button `CONFIGURE_SECRETS_LABEL` and its summary `summariseSecrets({ s3Key: <its key>, encryptionKey: undefined, geocodingKey: undefined }, true)`, written across lines. `bun run compile` passes.

6. **One label for going back in Receive and no em dashes in dialog text.** In `receive-database-dialog.tsx`, label both return buttons `BACK_LABEL`, with `data-id="receive-database-conflict-back"` on the `conflict` step's and `data-id="receive-database-name-conflict-back"` on the `db-name-conflict` step's. Rewrite the option texts as `Reuse existing: skip importing this secret`, `Replace existing: may break other databases using this secret` and `Replace existing: removes the existing entry, then imports the new one`. In `replicate-database-dialog.tsx`, rewrite the Full description as `Copies everything: every original, display and thumbnail file. Choose this when you want a complete, standalone copy that does not depend on the source.` `bun run compile` passes.

7. **Smoke tests that drove the Select buttons.** Add to `apps/photosphere-smoke-tests/lib/common.sh` a helper `choose_secret_in_configure_modal <port> <field: s3|encryption|geocoding> <name>` with a comment block, doing what `27-s3-replicate/test.sh` lines 108 to 127 do for one field: `wait_for_value "$port" configure-secrets-save "Save"`, click `configure-secrets-<field>-select`, `wait_for_value` the option `configure-secrets-<field>-option-<name>`, click it, `wait_for_value` the select reading back `<name>`, click `configure-secrets-save`, `wait_for_value_gone "$port" configure-secrets-save "Save" || return 1`. Then in each scenario below replace the `chosen-...-secret` waits, the `select-...-button` click, the `Select secret modal ready` wait and the `secret-select-button` click with a click on the dialog's configure button followed by this helper and wait for the dialog's secrets summary to contain the secret's name:
    - `apps/photosphere-smoke-tests/10-view-database/test.sh` (geocoding).
    - `apps/photosphere-smoke-tests/25-s3-database/test.sh` (S3, in both the New and the Add dialog, inside `open_s3_browser`).
    - `apps/photosphere-smoke-tests/26-s3-database-lifecycle/test.sh` (S3).
    - `apps/photosphere-smoke-tests/28-s3-failure/test.sh` (S3).
    - `apps/photosphere-smoke-tests/38-reset-device-s3/test.sh` (S3).
    The S3 row in the modal exists only once the type is S3, so each scenario switches the type before opening the modal, as it switches it before clicking `select-s3-button` today. Before editing, `grep -rn "select-s3-button\|select-encryption-button\|select-geocoding-button\|chosen-s3-secret\|chosen-encryption-secret\|chosen-geocoding-secret\|secret-select-button\|database-encrypted-switch" apps/photosphere-smoke-tests` and convert every match, including any added since this list was written. Run each listed scenario with `PHOTOSPHERE_SMOKE_SCENARIO=<n> bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=<n> bun run test:ziggy:and` and watch it pass.

8. **Cover the new labels and Receive's Back.**
    - `apps/photosphere-smoke-tests/41-receive-database/test.sh`: make it go through the name conflict once. Before launch, `create_database "$TMP_DIR/stale-received-db"`, seed it as `stale-received-db` and seed the database list with `[{name: "received-db", path: "stale-received-db"}]`. After the first `receive-database-save-button` click, `wait_for_value "$APP_PORT" receive-database-name-conflict-back "Back"`, click it, `wait_for_value "$APP_PORT" receive-database-save-button "Save"`, click Save again, `wait_for_value "$APP_PORT" receive-database-name-conflict-continue "Continue"`, click it (Replace is the default choice), then the existing `wait_for_log "$TMP_DIR" "Database imported"` and the rest. Update the scenario's comments, which say there is no name conflict. Run `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=41 bun run test:ziggy:and` and watch both pass.
    - `apps/photosphere-smoke-tests/2-create-database/test.sh`: after the dialog opens, `wait_for_value "$APP_PORT" create-database-secrets-summary "No secrets configured"`, so the scenario fails if the New dialog loses the shared secrets row. Run it on host and Android.

9. **Run the scenarios that drive these dialogs** and watch each pass on host and Android: `6-add-database-entry`, `17-replicate-database`, `22-edit-database-origin`, `27-s3-replicate`, `36-consolidate-database`, `45-s3-share-replica-sync`, `47-create-database-no-collision`, `52-encrypted-database` and `56-large-asset-push`.

10. **Update the documentation to match the code.**
    - `docs/database-names-and-paths.md`, "How a user gives a path", "In the app": every path field is labelled Path and shows `Folder path or s3:bucket/prefix`; secrets are chosen in every dialog with Configure secrets.
    - `docs/android-onboarding.md` (around lines 33, 153 and 154) and `docs/testing/e2e/mobile/auto-import/auto-import-existing-remote.md` (around lines 73 and 74): **Destination type** becomes **Type**, **Destination path** becomes **Path** and "Leave **Encrypted** off" becomes "Choose no encryption key in **Configure secrets…**".
    - `docs/testing/e2e/desktop/lan-share/share-database.md` step 3 (around line 79): replace the Encrypted switch and `select-encryption-button` with **Configure secrets…** (`create-database-configure-secrets-button`) and choosing `test-enc-key` in the Encryption key row (`configure-secrets-encryption-select`).
    - `grep -rn "select-s3-button\|select-encryption-button\|select-geocoding-button\|Select secret\|database-encrypted-switch\|Destination path\|Remote path\|Destination type\|Destination secrets" docs` and update every remaining match outside `docs/plans` and `docs/testing/e2e/CHECKLIST-NOTES.md`, which records past runs as they happened.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`, "Adding a Database": secrets are linked with **Configure secrets…**, which lists the S3 row only for an S3 database and offers **+ New** on each row; an encrypted database is one with an encryption key chosen.
    - Stories: `packages/user-interface/src/stories/modals/create-database-modal.stories.tsx` and `add-database-modal.stories.tsx` render inside `MockProviders`, whose `useApp()` supplies an empty secret list, which is all `ConfigureSecretsModal` needs. Remove the `select-secret-modal.stories.tsx` import and its spread from `packages/user-interface/src/stories/index.ts` (the files go in Clean up). Run `bun run stories:ziggy -- --headless --no-screenshots` and watch it report no failed story.

11. **Clean up.** `SelectSecretModal` has no user left (`grep -rn "SelectSecretModal" packages apps --include='*.tsx'` shows only its own file and its story). Delete `packages/user-interface/src/components/select-secret-modal.tsx` and `packages/user-interface/src/stories/modals/select-secret-modal.stories.tsx`. `bun run compile` and `bun run test` exit 0.

## Unit Tests

`packages/user-interface/src/test/lib/database-dialog-text.test.ts`, with a description at the top saying it checks the secrets summary every database dialog shows:

- No secrets and `s3Required` false gives `No secrets configured`; no secrets and `s3Required` true gives `S3 credentials required`.
- One secret gives just its part, for example `Encryption: family-key`.
- All three give `S3: a · Encryption: b · Geocoding: c`, in that order.
- A selection with secrets ignores `s3Required`.

The label constants get no test: they are literals and the smoke tests read them on screen. No unit tests for the dialogs: they are React components. Steps 7 to 9 cover them.

## Smoke Tests

- Converted to the Configure secrets modal, host and Android: `10-view-database`, `25-s3-database`, `26-s3-database-lifecycle`, `28-s3-failure`, `38-reset-device-s3`.
- `41-receive-database`, host and Android: a name conflict, Back to the review step, Save again and Replace.
- `2-create-database`, host and Android: the New dialog shows the shared secrets summary.
- The scenarios in step 9, host and Android, unchanged and passing.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=<n> bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=<n> bun run test:ziggy:and` exit 0 for each of 2, 10, 25, 26, 28, 38 and 41.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- Decided: "Path" for every path field. The dialog's title and its first line already say whose path it is (Replicate shows "Source: <name>" above the form, Consolidate says it keeps a copy on a remote), so the field does not need to say it again and New Database's form and Replicate's destination form now read the same.
- Decided: one placeholder, `Folder path or s3:bucket/prefix`. "Folder path" covers both a full path on a desktop and the simple name a phone user types, which the app resolves into its own storage. The form `s3:bucket/prefix` is the form the S3 browser returns and the storage layer reads.
- Decided: the Configure secrets modal everywhere, replacing the Select buttons. It already serves Edit and Replicate, it offers **+ New** on each row so a missing secret can be made without leaving the dialog and one button keeps the form short on a phone. The Encrypted switch goes because choosing an encryption key is what makes a database encrypted; the switch only revealed the key row.
- Decided: "Back" for both of Receive's return buttons, because both go back to the review step rather than abandoning the receive. "Cancel" stays for the buttons that close the dialog.
- The label constants are in one module because each is used in several dialogs; a constant used once would be inlined.
- `SelectSecretModal` logs `Select secret modal ready`. After step 7 no scenario waits for that line.
- The quick-create default name for New and Add is the typed name, or the path when the name is empty, as Edit's is.
