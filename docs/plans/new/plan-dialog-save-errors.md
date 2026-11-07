# Show save errors in the Create, Add and Edit database dialogs

## Overview

The New Database, Add Database and Edit Database dialogs treat a failed save as something only the log needs to hear about. A failure leaves the dialog sitting there with no message and in New Database it also leaves a database record behind for a database that was never made, so the next attempt with the same name is refused with "A database named ... already exists." The Replicate and Consolidate dialogs already show their failures in a danger `Alert`. This plan makes Create, Add and Edit do the same and makes Create remove the record it added when the database itself cannot be made.

## Issues

- `packages/user-interface/src/components/create-database-modal.tsx` `handleCreate` (around lines 147 to 157) calls `addDatabase` and then `createDatabaseAtPath`. When `createDatabaseAtPath` throws (for example the folder is not empty, or Android's picker gave a `content://` folder the app cannot write to, which `docs/testing/e2e/CHECKLIST-NOTES.md` records), the record stays in `databases.toml`, the dialog stays open with no message and the error reaches only `log.exception('Create database error:', ...)` in the button's `onClick`. Pressing Create again is refused by the name check because the broken record holds the name.
- `packages/user-interface/src/components/add-database-modal.tsx` `handleAdd` lets a failed `addDatabase` reject into the button's `.catch(log.exception)`. The dialog shows no message.
- `packages/user-interface/src/components/edit-database-modal.tsx` `handleSave` runs under `logExceptions(handleSave, 'Save error')`. A failed `setDatabaseOrigin` or `updateDatabase` is only logged.
- `packages/user-interface/src/context/asset-database-source.tsx` `createDatabaseAtPath` throws `create-database task did not succeed: <message>`. Shown to a user, the task name in front of the sentence is noise.

## Steps

1. **Write the create-then-roll-back sequence as a plain function.** Add `packages/user-interface/src/lib/create-listed-database.ts` exporting:
    - `ICreateListedDatabaseOperations`, an interface with three fields, each with a `//` comment: `addRecord: () => Promise<void>` (adds the database record), `createDatabase: () => Promise<void>` (makes the database at the record's path) and `removeRecord: () => Promise<void>` (removes the record again).
    - `createListedDatabase(operations: ICreateListedDatabaseOperations): Promise<void>`. It awaits `addRecord`, then `createDatabase`. When `addRecord` throws it rethrows that error and calls neither of the others. When `createDatabase` throws it awaits `removeRecord` and rethrows the error `createDatabase` threw. When `removeRecord` also throws it throws `new Error(`${createError.message} The database record could not be removed either: ${removeError.message}`)`, so neither failure is lost.
    - A comment block above the function saying why the record comes first: the `create-database` task (`packages-zig/node-api-zig/src/lib/create-database.worker.zig`) resolves S3 credentials and the encryption key from the database record whose path matches, so an S3 or encrypted database cannot be made before its record exists.
    Write `packages/user-interface/src/test/lib/create-listed-database.test.ts` (see Unit Tests). Run `bun run test -- create-listed-database` and watch it pass. `bun run compile` passes.

2. **Make the create task's error readable.** In `packages/user-interface/src/context/asset-database-source.tsx` `createDatabaseAtPath`, replace the thrown message `create-database task did not succeed: ${result?.errorMessage ?? "unknown error"}` with `result === undefined ? "Creating the database was cancelled before it finished." : (result.errorMessage || "The database could not be created.")`, with a one-line comment saying the message is shown to the user by the New Database dialog. `bun run compile` passes.

3. **New Database shows its error and leaves no record behind.** In `packages/user-interface/src/components/create-database-modal.tsx`:
    - Import `useApp`'s `removeDatabase` alongside `addDatabase`, `createListedDatabase` from `../lib/create-listed-database` and `Alert` from `@mui/joy/Alert`.
    - Add state `const [saveError, setSaveError] = useState<string | undefined>(undefined);` with a `//` comment ("The reason the last Create failed, shown above the buttons."). Clear it in the `open` effect and at the top of `handleCreate`.
    - Replace the `addDatabase` call and the `createDatabaseAtPath` call in `handleCreate` with a `try` around `await createListedDatabase({ addRecord: ..., createDatabase: () => createDatabaseAtPath(trimmedPath), removeRecord: () => removeDatabase(trimmedName) })`, where `addRecord` calls `addDatabase` with the same entry the code builds today and `trimmedPath` is `form.path.trim()` computed once. Write each object literal across lines, one property per line. In the `catch`, call `log.exception('Create database error:', err as Error)`, then `setSaveError((err as Error).message)` and return without closing. After the `try`, keep `log.info(`Database created: ...`)` and `onClose()`.
    - Render `{saveError && <Alert color="danger" data-id="create-database-error" sx={{ mt: 1 }}>{saveError}</Alert>}` as the last child of `DialogContent`.
    `bun run compile` passes.

4. **Add Database shows its error.** In `packages/user-interface/src/components/add-database-modal.tsx`, add the same `saveError` state and comment, cleared in the `open` effect and at the top of `handleAdd`. Put `await addDatabase(...)` in a `try`; in its `catch` call `log.exception('Add database error:', err as Error)`, `setSaveError((err as Error).message)` and return. `openDatabase` and `onClose` stay after the `try`, unchanged: `openDatabase` reports its own failures with a toast and the record it opens is a real one. Render `{saveError && <Alert color="danger" data-id="add-database-error" sx={{ mt: 1 }}>{saveError}</Alert>}` as the last child of `DialogContent`, importing `Alert`. `bun run compile` passes.

5. **Edit Database shows its error.** In `packages/user-interface/src/components/edit-database-modal.tsx`, add the same `saveError` state and comment, cleared in the `open` effect and at the top of `handleSave` next to `setNameError(undefined)`. Put the `if (entry) { ... } else { ... }` block that calls `setDatabaseOrigin`, `updateDatabase` and `addDatabase` in a `try`; in its `catch` call `log.exception('Save database error:', err as Error)`, `setSaveError((err as Error).message)` and return. `onClose()` stays after the `try`. Render `{saveError && <Alert color="danger" data-id="edit-database-error" sx={{ mt: 1 }}>{saveError}</Alert>}` as the last child of `DialogContent`, importing `Alert`. Leave the `logExceptions(handleSave, 'Save error')` wrapper on the button in place: it now only sees errors thrown outside the `try`. `bun run compile` passes.

6. **Add smoke scenario `apps/photosphere-smoke-tests/67-dialog-save-errors/test.sh`.** Model it on `36-consolidate-database/test.sh` (header comment, `source "$TEST_DIR/../lib/common.sh"`, `print_test_header 67 "dialog-save-errors"`, `trap 'cleanup_apps "$TMP_DIR"' EXIT`). It runs on every platform:
    - Before launch: `"${PLATFORM}_reset_app_state"`. Make two databases with the CLI: `create_database "$TMP_DIR/full-db" "$REPO_DIR/test/test.png"` (a folder that is not empty) and `create_database "$TMP_DIR/locked-db"`. Seed both with `"${PLATFORM}_seed_database"` as `full-db` and `locked-db`. Seed the database list with `"${PLATFORM}_seed_databases_config"` holding one record `{name: "Locked", path: <app path of locked-db>, encryptionKey: "missing-key"}`, built with `jq -cn` as test 36 builds its list. No secret named `missing-key` exists, so opening that database's storage fails with `Encryption key "missing-key" not found in vault` (`packages-zig/node-api-zig/src/lib/resolve-storage-credentials.zig`).
    - The paths a user types: on `android|ios` the short names `full-db` and `fresh-db`; on a desktop `$("${PLATFORM}_app_path" "full-db")` and `$TMP_DIR/fresh-db`. After `start_app` and `wait_for_ready`, on `android|ios` run `"${PLATFORM}_reset_path" "fresh-db"`, as `2-create-database/test.sh` does.
    - Create into the folder that is not empty: `click_sidebar_item "$APP_PORT" new-database`, wait for `Create database dialog opened`, type `Fresh Photos` into `database-name-input` and the full-db path into `database-path-input`, click `create-database-confirm`. `wait_for_value "$APP_PORT" create-database-error "already contains files"`. Assert `read_config_file databases.toml` does not contain `Fresh Photos` (fail with `log_error` and `exit 1` when `grep -q -F` finds it). Assert `create-database-confirm` still reads `Create` with `wait_for_value`.
    - Retry with an empty folder and the same name: type the fresh-db path into `database-path-input`, click `create-database-confirm`, `wait_for_log "$TMP_DIR" "Database created"`. Assert `read_config_file databases.toml` contains `Fresh Photos` exactly once (`grep -c -F`).
    - Edit the record whose key is missing: `send_command "$APP_PORT" navigate '{"page":"databases"}'`, wait for `Databases page loaded`, `click_database_row_action "$APP_PORT" 0 edit-database-button`, wait for `Edit database dialog opened`, type `Changed` into `edit-database-description-input`, click `save-database-button`. `wait_for_value "$APP_PORT" edit-database-error "missing-key"`. Assert `save-database-button` still reads `Save`.
    - `check_no_errors "$TMP_DIR" 'Create database error|already contains files|Save database error|missing-key'`, `stop_app`, `log_success "Test 67 passed: dialog-save-errors"`.
    Before writing the row index, read `seed_databases_config` and the databases page to confirm the seeded `Locked` record is row 0 after `Fresh Photos` is added (the page lists records in `databases.toml` order and `addDatabaseEntry` appends). Run `PHOTOSPHERE_SMOKE_SCENARIO=67 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=67 bun run test:ziggy:and` and watch both pass.

7. **Update the documentation to match the code.**
    - `docs/database-names-and-paths.md`, section "How a user gives a path", "In the app": the New database bullet says it adds the database record, creates the database at the path and opens it and that when the database cannot be created the record is removed again and the reason is shown in the dialog. The Add database and Edit database bullets say a failed save is shown in the dialog, which stays open.
    - `docs/testing/e2e/desktop/database/create-database-failure.md` and `docs/testing/e2e/mobile/database/create-database-failure.md`: new manual tests, written in the layout of `docs/testing/e2e/desktop/database/edit-database-origin.md` (the "Do not skip steps" line, Prep, Test, Check, Agent notes). Each creates a database into a folder that already holds one, checks the dialog shows the reason and `databases.toml` has no record for it, then creates it into an empty folder with the same name. List each in its folder's `README.md` and add `- [ ]` entries under "Database" in the Desktop and Mobile sections of `docs/testing/e2e/CHECKLIST.md`.
    - `~/projects/photosphere/photosphere.wiki/Managing-Databases.md`, "Adding a Database" and "Editing a Database": one sentence each saying a failed save is shown in the dialog and a database that cannot be created is not left in the list.
    - Stories: no change. `packages/user-interface/src/stories/modals/create-database-modal.stories.tsx`, `add-database-modal.stories.tsx` and `edit-database-modal.stories.tsx` render the dialogs before any save and the error only exists after one.

## Unit Tests

`packages/user-interface/src/test/lib/create-listed-database.test.ts`, with a description at the top saying it checks the order of the three operations and that a failure part way leaves no record. Each test passes `jest.fn` operations that push their name into an array, so the order is asserted:

- Adds the record and then creates the database and never removes the record, when both succeed.
- When adding the record fails, rethrows that error and neither creates the database nor removes the record.
- When creating the database fails, removes the record and rethrows the create error (the same error object).
- When creating the database fails and removing the record fails too, throws an error whose message holds both messages.

No unit tests for the three dialogs or for `createDatabaseAtPath`: they are React components and a context. Step 6 covers them.

## Smoke Tests

- `apps/photosphere-smoke-tests/67-dialog-save-errors` (new), host and Android: Create into a folder that is not empty shows `already contains files` in `create-database-error` and leaves no `Fresh Photos` record; Create again into an empty folder with the same name succeeds and leaves one record; Edit of a record whose encryption key is missing shows the key name in `edit-database-error` and the dialog stays open.
- `apps/photosphere-smoke-tests/2-create-database` and `47-create-database-no-collision` still pass: the success path of Create is unchanged.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=67 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=67 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0, in one run, as the final check.

## Notes

- Rejected: creating the database before adding the record. The `create-database` task finds the S3 credentials and the encryption key by looking up the record whose path matches (`resolveStorageCredentials` with null keys), so an S3 or encrypted database would fail to be made. The record goes first and is removed on failure.
- The removal is by name through `useApp().removeDatabase`, which is how every other removal in the interface works. The name was checked free just before, so it names only the record this attempt added.
- `createDatabaseAtPath` also tells the platform the database opened after the task succeeds. If only that last call fails, the record is still removed and the database stays on disk. Add Database registers it again. This case is not split out because it needs a change to the shared context for a failure that has not been seen.
- Add Database gets no smoke assertion of its error. Once the name check passes, no input a user can give makes `add-database` fail: its only refusal is a taken name, which the dialog checks first. The display code is the same few lines as Create and Edit, which the smoke scenario does drive.
- The message is `err.message` as the platform rejected it, matching Replicate (`err.message`) and Consolidate (`taskResult.errorMessage`). No prefix is added.
- Edit writes the origin into the database's own config and then updates the record. If the first succeeds and the second fails, a second Save writes both again, which the existing comment in `handleSave` already relies on.
- Rejected: disabling the confirm button while a save runs. It is a separate behaviour and no dialog here does it.
