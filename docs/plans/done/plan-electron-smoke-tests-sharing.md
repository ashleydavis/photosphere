# Electron Smoke Tests: Share Secret and Share Database

## Overview
Add two Electron smoke tests (tests 7 and 8) that verify end-to-end LAN sharing of a
secret and a database through the Electron app. Each test runs two isolated app instances
(sender and receiver) driven by the existing `click`, `type`, `navigate`, and
`wait_for_log` infrastructure. To make UI automation possible, `data-id` attributes are
added to the relevant buttons, inputs, and the pairing code display in the share/receive
dialogs and pages. A single new read-only `GET /get-value` endpoint is added to the test
control server so the test can read the displayed pairing code from the sender's DOM —
the programmatic equivalent of a human reading the code off the screen — and type it into
the receiver. After transfer, the test verifies that the names of the secret, the database,
and any secrets linked to the database are identical on the receiver.

## Issues

## Steps

1. **Add `data-id` to the "Receive Secret" button in `packages/user-interface/src/pages/secrets/secrets-page.tsx`**
   Add `data-id="receive-secret-button"` to the button that sets `receiveDialogOpen(true)`.

2. **Add `data-id` to the per-row "Share secret" icon button in `packages/user-interface/src/pages/secrets/secrets-page.tsx`**
   Add `data-id={`share-secret-button-${secret.name}`}` to the `IosShare` icon button in
   each secret list row.

3. **Add `data-id` to the "Receive Database" button in `packages/user-interface/src/pages/databases/databases-page.tsx`**
   Add `data-id="receive-database-button"` to the button that sets `receiveDbDialogOpen(true)`.

4. **Add `data-id` to the per-row "Share database" icon button in `packages/user-interface/src/pages/databases/databases-page.tsx`**
   Add `data-id={`share-database-button-${entry.name}`}` to the `IosShare` icon button in
   each database list row.

5. **Add `data-id` attributes to `packages/user-interface/src/components/share-secret-dialog.tsx`**
   - Add `data-id="share-secret-send-button"` to the "Send" button.
   - Add `data-id="share-pairing-code"` to the `Typography` element that renders `{pairingCode}`.

6. **Add `data-id` attributes to `packages/user-interface/src/components/share-database-dialog.tsx`**
   - Add `data-id="share-database-send-button"` to the "Send" button.
   - Add `data-id="share-pairing-code"` to the `Typography` element that renders `{pairingCode}`.

7. **Add `data-id` attributes to `packages/user-interface/src/components/receive-secret-dialog.tsx`**
   - Add `data-id="receive-secret-code-input"` to the code `Input`.
   - Add `data-id="receive-secret-start-button"` to the "Start" button.
   - Add `data-id="receive-secret-save-button"` to the "Save" button.

8. **Add `data-id` attributes to `packages/user-interface/src/components/receive-database-dialog.tsx`**
   - Add `data-id="receive-database-code-input"` to the code `Input`.
   - Add `data-id="receive-database-start-button"` to the "Start" button.
   - Add `data-id="receive-database-save-button"` to the "Save" button.

9. **Add a `test-get-value` IPC handler to `apps/desktop-frontend/src/index.tsx`**
   In the existing test-mode block alongside `test-click` and `test-type`, add a handler
   for `test-get-value` that:
   - Receives `{ dataId: string }`.
   - Queries `document.querySelector(`[data-id="${data.dataId}"]`)`.
   - Reads `(element as HTMLInputElement).value || element.textContent || ''`.
   - Sends the result back via `electronAPI.sendMessage('test-value-response', { value })`.

10. **Add `sendMessage` to the renderer-side Electron API if not already present**
    Check `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` and the preload
    script. If there is no existing way for the renderer to send an arbitrary IPC message
    to the main process, add `sendMessage(channel: string, data: unknown): void` to the
    preload's `contextBridge` exposure, implemented as `ipcRenderer.send(channel, data)`.

11. **Add `GET /get-value` endpoint to `apps/desktop/src/lib/test-control-server.ts`**
    - Import `ipcMain` from `electron` (add to existing import).
    - Add a `GET /get-value` route: reads `req.query.dataId`, sends `test-get-value` IPC
      to the renderer, waits for a single `test-value-response` reply via `ipcMain.once`,
      then responds `{ ok: true, value }`.

12. **Add log messages to the receive dialogs for test synchronisation**
    - In `receive-secret-dialog.tsx`: `log.info('Receive secret dialog opened')` in the
      `useEffect` when `open` becomes true, and `log.info('Secret saved')` after
      `setStep("success")` in `handleSave`.
    - In `receive-database-dialog.tsx`: `log.info('Receive database dialog opened')` on
      open, `log.info('Database review step')` when `setStep("review")` is called in
      `handleStartReceiving`, and `log.info('Database imported')` after `setStep("success")`
      in `doImport`.

13. **Create `apps/desktop/smoke-tests/7-share-secret/test.sh`**
    - `print_test_header 7 "share-secret"`.
    - Use two ports (`$SENDER_PORT`, `$RECEIVER_PORT`) and two tmp subdirs (`sender/`, `receiver/`).
    - Seed `$TMP_DIR/sender/vault/test-secret.json`:
      `{"name":"test-secret","type":"api-key","value":"{\"label\":\"Test Key\",\"apiKey\":\"TESTAPIKEY123\"}"}`.
    - Start sender app with `PHOTOSPHERE_VAULT_DIR=$TMP_DIR/sender/vault`,
      `PHOTOSPHERE_CONFIG_DIR=$TMP_DIR/sender/config`, `PHOTOSPHERE_LOG_DIR=$TMP_DIR/sender`
      on `$SENDER_PORT`. `wait_for_ready $SENDER_PORT`.
    - `send_command $SENDER_PORT navigate '{"page":"secrets"}'`.
    - `wait_for_log $TMP_DIR/sender "Secrets page loaded"`.
    - `send_command $SENDER_PORT click '{"dataId":"share-secret-button-test-secret"}'`.
    - Wait for the pairing code element to be populated, then read it:
      `code=$(curl -sf "http://localhost:$SENDER_PORT/get-value?dataId=share-pairing-code" | sed 's/.*"value":"\([^"]*\)".*/\1/')`.
    - `send_command $SENDER_PORT click '{"dataId":"share-secret-send-button"}'`.
    - Start receiver app with empty vault/config/log dirs on `$RECEIVER_PORT`. `wait_for_ready $RECEIVER_PORT`.
    - `send_command $RECEIVER_PORT navigate '{"page":"secrets"}'`.
    - `wait_for_log $TMP_DIR/receiver "Secrets page loaded"`.
    - `send_command $RECEIVER_PORT click '{"dataId":"receive-secret-button"}'`.
    - `wait_for_log $TMP_DIR/receiver "Receive secret dialog opened"`.
    - `send_command $RECEIVER_PORT type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"`.
    - `send_command $RECEIVER_PORT click '{"dataId":"receive-secret-start-button"}'`.
    - `wait_for_log $TMP_DIR/receiver "Secret saved"`.
    - Assert `$TMP_DIR/receiver/vault/test-secret.json` exists.
    - Assert the file contains `"name":"test-secret"`.
    - `check_no_errors $TMP_DIR/sender` and `check_no_errors $TMP_DIR/receiver`.
    - Stop both apps. `log_success "Test 7 passed: share-secret"`.

14. **Create `apps/desktop/smoke-tests/8-share-database/test.sh`**
    - `print_test_header 8 "share-database"`.
    - Seed `$TMP_DIR/sender/vault/test-s3-key.json` (type `s3-credentials`) and
      `$TMP_DIR/sender/vault/test-enc-key.json` (type `encryption-key`).
    - Seed `$TMP_DIR/sender/config/databases.json` with entry name `test-db`,
      `s3Key: "test-s3-key"`, `encryptionKey: "test-enc-key"`, path `/tmp/smoke-test-db`.
    - Start sender app with sender vault/config/log dirs on `$SENDER_PORT`. `wait_for_ready $SENDER_PORT`.
    - `send_command $SENDER_PORT navigate '{"page":"databases"}'`.
    - `wait_for_log $TMP_DIR/sender "Databases page loaded"`.
    - `send_command $SENDER_PORT click '{"dataId":"share-database-button-test-db"}'`.
    - Read pairing code via `GET /get-value?dataId=share-pairing-code` on sender.
    - `send_command $SENDER_PORT click '{"dataId":"share-database-send-button"}'`.
    - Start receiver app with empty vault/config/log dirs on `$RECEIVER_PORT`. `wait_for_ready $RECEIVER_PORT`.
    - `send_command $RECEIVER_PORT navigate '{"page":"databases"}'`.
    - `wait_for_log $TMP_DIR/receiver "Databases page loaded"`.
    - `send_command $RECEIVER_PORT click '{"dataId":"receive-database-button"}'`.
    - `wait_for_log $TMP_DIR/receiver "Receive database dialog opened"`.
    - `send_command $RECEIVER_PORT type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}"`.
    - `send_command $RECEIVER_PORT click '{"dataId":"receive-database-start-button"}'`.
    - `wait_for_log $TMP_DIR/receiver "Database review step"`.
    - `send_command $RECEIVER_PORT click '{"dataId":"receive-database-save-button"}'`.
    - `wait_for_log $TMP_DIR/receiver "Database imported"`.
    - Assert `$TMP_DIR/receiver/config/databases.json` exists and contains `"test-db"`.
    - Assert `$TMP_DIR/receiver/vault/test-s3-key.json` exists and contains `"name":"test-s3-key"`.
    - Assert `$TMP_DIR/receiver/vault/test-enc-key.json` exists and contains `"name":"test-enc-key"`.
    - `check_no_errors $TMP_DIR/sender` and `check_no_errors $TMP_DIR/receiver`.
    - Stop both apps. `log_success "Test 8 passed: share-database"`.

## Unit Tests
No new unit tests required. The sharing logic is covered by existing CLI LAN share smoke
tests. These tests exercise only the UI plumbing and end-to-end integration.

## Smoke Tests
- `./smoke-tests.sh 7` — passes; receiver vault contains `test-secret.json` with name `test-secret`.
- `./smoke-tests.sh 8` — passes; receiver config has `test-db`; receiver vault contains
  `test-s3-key.json` and `test-enc-key.json` with matching names.
- `./smoke-tests.sh` — all 8 tests pass.

## Verify
- `bun run compile` from repo root — no TypeScript errors.
- `./smoke-tests.sh 7` exits 0.
- `./smoke-tests.sh 8` exits 0.
- Receiver vault filenames exactly match sender secret names (grep assertions in test scripts).

## Notes
- `GET /get-value` is the programmatic equivalent of a human reading the pairing code off
  the screen. The code is never written to any log file.
- The endpoint uses `ipcMain.once` for the round-trip to the renderer, which is safe for
  sequential smoke tests.
- The pairing code display element must be rendered before `/get-value` is called. The
  share dialog enters the `showing-code` step synchronously before any async network
  operations, so polling `/get-value` immediately after clicking the share button is safe;
  if the element is empty, the test can retry with a short sleep before asserting.
- Each app instance needs its own `PHOTOSPHERE_VAULT_DIR`, `PHOTOSPHERE_CONFIG_DIR`,
  `PHOTOSPHERE_LOG_DIR`, and `PHOTOSPHERE_TEST_PORT` to stay fully isolated.
- Vault files are written as `<name>.json` by the plaintext vault; the name assertions
  verify the file exists with the exact sender-side name, confirming no rename occurred.
