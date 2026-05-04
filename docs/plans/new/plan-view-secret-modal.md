# View Secret / View Database Modals

## Overview
Add a "View" button to each row in the Manage Secrets table that opens a modal displaying the secret's value. The value is masked on open (shown as `••••••••••`). The user must click a "Reveal" button to fetch and display the actual value — the secret value is not sent from the main process to the frontend until that moment.

Also add a "View" button to each row in the Manage Databases table that opens a modal showing the database's details and its linked secrets. Each linked secret entry shows its name and a "View Secret" button that opens the same `ViewSecretDialog` used from the Manage Secrets page.

## Issues
<!-- Leave empty — populated later by plan:check -->

## Steps

1. **Create `packages/user-interface/src/components/view-secret-dialog.tsx`**
   - Define `IViewSecretDialogProps` interface with fields: `open: boolean`, `secret: ISharedSecretEntry`, `onClose: () => void`, `getSecretValue: (id: string) => Promise<string | undefined>`.
   - Add component state: `revealed: boolean`, `secretValue: string | undefined`, `loading: boolean`.
   - Reset state whenever `open` changes to `true` (via `useEffect` on `open`).
   - When not revealed, display the masked placeholder `"••••••••••"` in a `Typography` element.
   - "Reveal" button: `data-id="reveal-secret-button"`. On click, call `getSecretValue(secret.id)`, set `secretValue`, set `revealed = true`, emit `log.info('Secret revealed')`. Use `loading` to disable the button during the call.
   - When revealed, display the result of `formatSecretForDisplay(secretValue)` in a `<pre>`-style box.
   - Layout: `ModalDialog` with `DialogTitle` ("View Secret"), `DialogContent` (secret name, type, and value area), `DialogActions` (Close button on the left, Reveal button on the right — hidden once revealed).
   - Export `formatSecretForDisplay(valueJson: string): string` as a named export for testability. It calls `JSON.stringify(JSON.parse(valueJson), null, 2)` and returns the result.

2. **Edit `packages/user-interface/src/pages/secrets/secrets-page.tsx`**
   - Import `ViewSecretDialog` from `../../components/view-secret-dialog`.
   - Import `Visibility` from `@mui/icons-material`.
   - Add state variable `viewingSecret: ISharedSecretEntry | undefined` (default `undefined`).
   - In each table row's Actions cell, add an `IconButton` (before the Share button) with `data-id="view-secret-button"`, `title="View secret"`, `size="sm"`, `variant="plain"`, `onClick={() => { log.info('View secret dialog opened'); setViewingSecret(secret); }}`, rendering `<Visibility fontSize="small" />`.
   - Widen the Actions column `<th>` `width` style to accommodate the extra button (from `112px` to `140px`).
   - Render `<ViewSecretDialog>` below the other modals, open when `viewingSecret !== undefined`, passing `secret={viewingSecret!}`, `onClose={() => setViewingSecret(undefined)}`, and `getSecretValue={platform.getSecretValue}`.

3. **Create `packages/user-interface/src/components/view-database-dialog.tsx`**
   - Define `IViewDatabaseDialogProps` interface with fields: `open: boolean`, `entry: IDatabaseEntry`, `allSecrets: ISharedSecretEntry[]`, `onClose: () => void`, `getSecretValue: (id: string) => Promise<string | undefined>`.
   - Add component state: `viewingSecret: ISharedSecretEntry | undefined`.
   - Layout: `ModalDialog` with `DialogTitle` ("View Database"), `ModalClose`, `DialogContent`, `DialogActions` (Close button).
   - `DialogContent` shows: Name, Description, Path, and Origin as labelled read-only rows.
   - Below those rows, show a "Linked Secrets" section. For each of the three possible secret keys (`s3Key` → "S3 Credentials", `encryptionKey` → "Encryption Key", `geocodingKey` → "Geocoding API Key"): if the `IDatabaseEntry` field is set, look up the matching `ISharedSecretEntry` from `allSecrets` by `id`, display its name, and show a small `Button` that sets `viewingSecret` to that entry. If the field is not set, display "None". Button `data-id` values: `"view-secret-s3-button"`, `"view-secret-encryption-button"`, `"view-secret-geocoding-button"`.
   - Render `<ViewSecretDialog>` inside the component, open when `viewingSecret !== undefined`, passing the looked-up entry, `onClose={() => setViewingSecret(undefined)}`, and the forwarded `getSecretValue` prop.
   - Import `ViewSecretDialog` from `./view-secret-dialog`.

4. **Edit `packages/user-interface/src/pages/databases/databases-page.tsx`**
   - Import `ViewDatabaseDialog` from `../../components/view-database-dialog`.
   - Import `Visibility` from `@mui/icons-material`.
   - Add state variable `viewingEntry: IDatabaseEntry | undefined` (default `undefined`).
   - In each table row's Actions cell, add an `IconButton` (before the Open button) with `data-id="view-database-button"`, `title="View database"`, `size="sm"`, `variant="plain"`, `onClick={() => { log.info('View database dialog opened'); setViewingEntry(entry); }}`, rendering `<Visibility fontSize="small" />`.
   - Widen the Actions column `<th>` `width` style to accommodate the extra button (from `112px` to `140px`).
   - Render `<ViewDatabaseDialog>` below the other modals, open when `viewingEntry !== undefined`, passing `entry={viewingEntry!}`, `allSecrets={[...s3Secrets, ...encryptionSecrets, ...geocodingSecrets]}`, `onClose={() => setViewingEntry(undefined)}`, and `getSecretValue={platform.getSecretValue}`.

5. **Create `apps/desktop/smoke-tests/9-view-secret/test.sh`**
   - Follow the pattern of `5-add-secret/test.sh`.
   - Start the app, navigate to `secrets`, wait for `"Secrets page loaded"`.
   - Add an api-key secret named `"smoke-secret"` via `add-secret-button`, `secret-name-input`, and `add-secret-confirm` (reusing the same flow as test 5), wait for `"Secret added"`.
   - Click `view-secret-button`, wait for `"View secret dialog opened"`.
   - Click `reveal-secret-button`, wait for `"Secret revealed"`.
   - `check_no_errors`, `stop_app`, `log_success`.

6. **Create `apps/desktop/smoke-tests/10-view-database/test.sh`**
   - Follow the pattern of `6-add-database-entry/test.sh`.
   - Pre-create a database with the CLI (`bun run start -- init --db "$TMP_DIR/test-db" --yes`).
   - Start the app, navigate to `secrets`, wait for `"Secrets page loaded"`.
   - Add an api-key secret named `"smoke-geocoding"` (same flow as test 5), wait for `"Secret added"`.
   - Navigate to `databases`, wait for `"Databases page loaded"`.
   - Add a database entry linked to the geocoding secret via `add-database-button`, fill in name and path, select the geocoding key, confirm — wait for `"Database entry added"`.
   - Click `view-database-button`, wait for `"View database dialog opened"`.
   - Click `view-secret-geocoding-button`, wait for `"View secret dialog opened"`.
   - Click `reveal-secret-button`, wait for `"Secret revealed"`.
   - `check_no_errors`, `stop_app`, `log_success`.

## Unit Tests

- **File: `packages/user-interface/src/test/lib/view-secret-dialog.test.ts`**
  - Test `formatSecretForDisplay` with an S3-credentials JSON string — expect pretty-printed JSON with indentation.
  - Test `formatSecretForDisplay` with an encryption-key JSON string.
  - Test `formatSecretForDisplay` with an api-key JSON string.

## Smoke Tests

Run with `bun run test:electron` from the repo root, or individually:

```
cd apps/desktop && bash smoke-tests.sh 9
cd apps/desktop && bash smoke-tests.sh 10
```

Test 9 (`view-secret`) verifies the full View Secret flow on the Manage Secrets page: add a secret, open the View dialog, confirm value is masked, click Reveal, confirm the secret is fetched.

Test 10 (`view-database`) verifies the View Database flow end-to-end: add a secret, add a database linked to that secret, open the View Database dialog, open the nested View Secret dialog for the linked secret, click Reveal.

## Verify

- `bun run compile` — no TypeScript errors.
- `bun run test` — all existing tests pass; new `formatSecretForDisplay` tests pass.
- `cd apps/desktop && bash smoke-tests.sh 9` — passes.
- `cd apps/desktop && bash smoke-tests.sh 10` — passes.

## Notes

- `getSecretValue` (in `platform-context.tsx`) and the `vault-get` IPC handler (in `main.ts`) already exist; no backend changes are needed.
- Both new components receive `getSecretValue` as a prop rather than calling `usePlatform()` directly, keeping them testable and decoupled.
- `ViewSecretDialog` state resets on `open` change so reopening always starts masked.
- The value is displayed as pretty-printed JSON rather than type-specific field layout, keeping the component simple and type-agnostic.
- `formatSecretForDisplay` is a pure function exported separately so it can be tested without rendering the component.
- `allSecrets` in `ViewDatabaseDialog` is built by concatenating the three already-loaded secret lists in `DatabasesPage` — no extra fetch is needed.
- The smoke tests depend on `log.info` calls at key interaction points; these must be added exactly as specified in Steps 2 and 4.
- Test 10 needs to know how to select a secret in the add-database form — check the `data-id` pattern used by existing selectors in `add-database-modal` or `databases-page.tsx` before writing the test script.
