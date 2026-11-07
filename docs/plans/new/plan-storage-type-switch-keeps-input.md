# Keep the typed path when the storage type Select reports the type it already has

## Overview

The New Database and Add Database dialogs clear the path and the chosen S3 credentials whenever the **Type** Select calls its `onChange`, whether or not the type changed. Joy's Select calls `onChange` again on re-renders that it did not cause (the replicate dialog hit this in its smoke test, as the comment on `applyDestinationTypeChange` in `packages/user-interface/src/lib/replicate-form.ts` records), so a path the user typed can be wiped by a report of the type the form already holds. On a real change the dialogs clear `s3Key` but leave `s3SecretName`, so switching from S3 to File system and back shows the old secret's name beside a form that holds no secret and **Browse S3** is disabled with no visible reason.

This plan moves the rule into one tested function shared by both dialogs, returns the previous state when the type is unchanged and clears `s3SecretName` on a real change.

## Issues

- `packages/user-interface/src/components/create-database-modal.tsx` line 251: `onChange={(_event, value) => setForm(prev => ({ ...prev, storageType: value as StorageType, path: '', s3Key: undefined }))}` clears `path` and `s3Key` on every call and leaves `s3SecretName` (line 92) set.
- `packages/user-interface/src/components/add-database-modal.tsx` line 242: the same handler, with the same two faults (`s3SecretName` is line 92).
- The Type Select's File system option has no `data-id` in either dialog (`create-database-modal.tsx` line 254, `add-database-modal.tsx` line 245), so a smoke test cannot pick it.

## Steps

1. **Add the shared rule.** Create `packages/user-interface/src/lib/storage-type-change.ts`:
    - A file comment saying it holds the rule for changing the storage type of the New Database and Add Database forms, kept out of the components so it can be tested directly.
    - `export interface IStorageTypeFields` with three commented fields: `storageType: 'filesystem' | 's3'` (the storage back-end the form is set to), `path: string` (the path typed or browsed for that back-end) and `s3Key: string | undefined` (the S3 credentials secret chosen for an S3 path).
    - `export function applyStorageTypeChange<FormState extends IStorageTypeFields>(previous: FormState, value: string | null): FormState`. It computes `const storageType = (value as IStorageTypeFields['storageType']) ?? 'filesystem';`. When `storageType === previous.storageType` it returns `previous` itself. Otherwise it returns a new object literal, one property per line: `...previous,`, `storageType,`, `path: '',`, `s3Key: undefined,`.
    - The comment above the function says why: a path written for one back-end is meaningless to the other and S3 credentials are meaningless for a file system path, so a real change clears both; Joy's Select calls `onChange` again on re-renders it did not cause, so a report of the type already held must return the same object and leave what the user typed alone. It names `applyDestinationTypeChange` in `replicate-form.ts` as the same rule for the replicate dialog.

2. **Unit test the rule.** Create `packages/user-interface/src/test/lib/storage-type-change.test.ts`, laid out like `src/test/lib/replicate-form.test.ts`, with a description comment at the top giving the goal (the storage type rule shared by the New Database and Add Database dialogs) and the method (calling `applyStorageTypeChange` on plain form objects). Use a local `IFormForTest extends IStorageTypeFields` that adds `name` and `encryptionKey` fields and a `filledS3Form()` helper returning an S3 form with a path, an `s3Key`, a name and an encryption key. Tests (each with `test(`):
    - Reporting the type the form already holds returns the same object (`toBe`), for both `'s3'` on the S3 form and `'filesystem'` on a filesystem form with a typed path.
    - Changing from File system to S3 sets `storageType` to `'s3'` and clears `path`.
    - Changing from S3 to File system clears `path` and `s3Key`.
    - A real change keeps every other field (`name`, `encryptionKey`).
    - A `null` value is read as File system: on a filesystem form it returns the same object, on the S3 form it changes to File system.
    - Run `bun run test -- storage-type-change` and see it exit 0.

3. **Use it in New Database.** In `packages/user-interface/src/components/create-database-modal.tsx`:
    - Import `applyStorageTypeChange` from `'../lib/storage-type-change'` with the other `../lib` import.
    - Replace the Select's `onChange` (line 251) with a block-bodied arrow function: `setForm(prev => applyStorageTypeChange(prev, value as string | null));`, then an `if (value !== form.storageType) {` block that calls `setS3SecretName(undefined);`. Put a comment above it saying the secret's name is shown beside the S3 Credentials row and has to go with the `s3Key` it names and only on a real change.
    - Add `data-id="database-storage-type-option-filesystem"` to the File system `Option` (line 254).
    - Run `bun run compile` and see it exit 0.

4. **Use it in Add Database.** Make the same three edits in `packages/user-interface/src/components/add-database-modal.tsx` (import, the `onChange` at line 242, the File system `Option` at line 245). Run `bun run compile` and see it exit 0.

5. **Cover the secret name with a smoke check.** In `apps/photosphere-smoke-tests/25-s3-database/test.sh`, add a third section after `close_s3_browser` of section 2 and before `check_no_errors`, headed `# --- 3. Changing the type away from S3 and back clears the path and the chosen secret. ---`:
    - Open the dialog as `open_s3_browser` does (the same `case "$PLATFORM"` block: on a phone navigate to databases, wait for "Databases page loaded", open `page-actions-menu`, click `add-database-button`, wait for "Add database dialog opened"; on a desktop `click_sidebar_item "$APP_PORT" new-database` and wait for "Create database dialog opened"). Factor that block into a function `open_add_dialog` in the file, with a comment and call it from both `open_s3_browser` and the new section, so the two cannot drift apart.
    - Pick S3 (`database-storage-type-select`, then `database-storage-type-option-s3`), wait for `chosen-s3-secret` to read `None selected`, pick the secret (`select-s3-button`, wait for the log "Select secret modal ready", click `secret-select-button`) and wait for `chosen-s3-secret` to read `$SECRET_NAME`.
    - Type `s3:$S3_EMULATOR_BUCKET/typed-path` into `database-path-input` with `jq -cn` and `wait_for_value "$APP_PORT" database-path-input "typed-path"`.
    - Pick File system (`database-storage-type-select`, then `database-storage-type-option-filesystem`) and `wait_for_value_gone "$APP_PORT" database-browse-button "S3" || exit 1` (the button reads **Browse S3** only for S3).
    - Assert the path was cleared: `assert_value` cannot match an empty value, so read it with `read_value "$APP_PORT" database-path-input` and fail with `log_error` and `exit 1` when it is not empty.
    - Pick S3 again and `wait_for_value "$APP_PORT" chosen-s3-secret "None selected"`. Before this change it reads `$SECRET_NAME` and the wait times out.
    - Cancel the dialog (`add-database-cancel` on a phone, `create-database-cancel` on a desktop) and `log_success "Changing the storage type clears the path and the chosen secret"`.
    - Extend the comment at the top of the file with a third numbered behaviour describing this section.
    - Run `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` and `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` and see both exit 0.

6. **Update the documentation.** In `docs/database-names-and-paths.md`, section "In the app", extend the "New database" bullet with one sentence: changing the type clears the path and the chosen S3 credentials and choosing the type already selected keeps them. In `docs/testing/e2e/desktop/database/open-existing-database.md` step 1.3, extend the **Type** (`database-storage-type-select`) bullet with the same sentence and the option `data-id`s (`database-storage-type-option-filesystem`, `database-storage-type-option-s3`).

## Unit Tests

- `applyStorageTypeChange` (`packages/user-interface/src/test/lib/storage-type-change.test.ts`): an unchanged type returns the same object; a real change in either direction clears `path` and `s3Key` and keeps every other field; `null` is read as File system.

## Smoke Tests

- `apps/photosphere-smoke-tests/25-s3-database`, new section 3: with S3 chosen, a secret picked and a path typed, switching to File system clears the path and switching back to S3 shows `None selected` for the S3 credentials.

## Verify

- `bun run compile` exits 0.
- `bun run test` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy` exits 0.
- `PHOTOSPHERE_SMOKE_SCENARIO=25 bun run test:ziggy:and` exits 0.
- `bun run tev` exits 0.

## Notes

- The unchanged case is covered by the unit test, not by a smoke check. Picking the option already selected does not call `onChange`: Base UI's `useList` compares the selected values with `areArraysEqual` before reporting a change (`node_modules/@mui/base/useList/useList.js`, the `selectedValues` comparer), so a smoke check that re-picks S3 passes with or without the fix. The re-render reports Joy makes on its own are not something a test can cause on demand.
- A new file is used because the rule belongs to two components and has no existing home: `replicate-form.ts` is the replicate dialog's form state. The function is generic over the form so each dialog keeps its own form interface.
- `form.storageType` is read from the render's closure for the `s3SecretName` decision. Joy's `useSelect` rebuilds the handler it calls whenever the `onChange` prop changes (`node_modules/@mui/base/useSelect/useSelect.js`, `handleSelectionChange` with `[multiple, onChange]` as its dependencies), so the handler it calls is the current render's. The form itself is still updated with the `prev` updater, as the replicate dialog does.
- `encrypted` and `encryptionKey` are left as they are on a type change. Encryption applies to both back-ends.
- No other code calls these `onChange` handlers. Scenarios 26, 28 and 38 pick S3 once on a fresh form, which the change leaves as it was.
