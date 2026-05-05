# Migrate Vault Format for `encryption-key` and `api-key` Secrets

## Overview

Commit `9be041a0` switched the desktop add/edit flow over to a simplified vault storage model: `encryption-key` values are stored as a raw private-key PEM string and `api-key` values are stored as a raw key string, while `s3-credentials` values are still a JSON object but with the `label` field removed. The user-typed name becomes the vault key directly (no random 8-char id, no `{ label, ... }` wrapper).

Several other code paths still produce or consume the OLD format and have not been updated. The clearest symptom is Electron smoke test #8 (`8-share-database`), which seeds the sender's vault with the OLD wrapped JSON shape; once the receiver opens that database the new edit flow throws "SyntaxError: No number after minus sign in JSON at position 1" because it expects a raw PEM/key string.

This plan migrates every remaining producer and consumer of the old format to the new format. After this plan, the vault contains only:
- `s3-credentials` → JSON `{ region, accessKeyId, secretAccessKey, endpoint? }` (no `label`).
- `encryption-key` → raw private-key PEM string.
- `api-key` → raw key string.

Backward compatibility for the old format is intentionally NOT preserved — this matches the project rule "Backward compatibility is not required."

## Issues

<!-- Populated later by plan:check -->

## Steps

### A. Production code — CLI

1. Edit `apps/cli/src/cmd/dbs.ts` function `createSharedSecret()`:
   - Lines 243–252 (`s3-credentials` branch): drop `label` from the value object. Build `value` as `{ region, accessKeyId, secretAccessKey }` and conditionally add `endpoint`. The `label` prompt is no longer needed for storage; either remove the prompt entirely or keep it only for the success log message. Remove the unused `label` from the `JSON.stringify` call.
   - Lines 288–292 (`encryption-key` branch): change `value: JSON.stringify({ label, privateKeyPem, publicKeyPem })` to `value: privateKeyPem`. Drop the `publicKeyPem` and `label` from storage. Keep `label` only for the success log message.
   - Lines 300–304 (`api-key` branch): change `value: JSON.stringify({ label, apiKey })` to `value: apiKey`. Keep `label` only for the success log.
2. Edit `apps/cli/src/cmd/dbs.ts` function `pickOrCreateSecret()` lines 164–184: remove the `JSON.parse(secret.value) → parsed.label` extraction. Display label is just `secret.name` for every type now. Delete the `try/catch` block; set `displayLabel = secretId` directly.

### B. Production code — LAN share import/resolve

3. Edit `packages/lan-share/src/lib/lan-share-import.ts` function `importDatabasePayload()`:
   - Lines 49–59 (`s3-credentials`): change the stored value to `JSON.stringify({ region, accessKeyId, secretAccessKey, endpoint: payload.s3Credentials.endpoint })` — no `label`.
   - Lines 68–76 (`encryption-key`): change to `value: payload.encryptionKey.privateKeyPem` (raw string, no JSON wrapping, drop `publicKeyPem` from storage).
   - Lines 85–92 (`api-key`): change to `value: payload.geocodingKey.apiKey` (raw string).
4. Edit `packages/lan-share/src/lib/lan-share-resolve.ts` function `resolveDatabaseSharePayload()`:
   - Lines 14–28 (`s3Credentials` block): keep `JSON.parse` (still valid format) but drop the `parsed.label || …` line. Set `label: entry.s3Key` directly so the receiver still has a non-empty display string.
   - Lines 30–51 (`encryptionKey` block): remove the `try/catch` and the JSON-parse branch entirely. Always treat `secret.value` as a raw PEM string: `privateKeyPem = secret.value; publicKeyPem = exportPublicKeyToPem(createPublicKey(createPrivateKey(secret.value)));`. Set `label = entry.encryptionKey`.
   - Lines 53–64 (`geocodingKey` block): replace `const parsed = JSON.parse(secret.value); … apiKey: parsed.apiKey` with `apiKey: secret.value`. Set `label: entry.geocodingKey`.

### C. Production code — desktop main process

5. Edit `apps/desktop/src/main.ts`:
   - Lines 404–412 (`get-database-secrets`, encryption branch): replace the `JSON.parse(encryptionSecret.value)` block with a raw-PEM read. Use `createPrivateKey`/`createPublicKey` from `node:crypto` and `exportPublicKeyToPem` from `storage` to derive the public key. Build `secrets.encryptionKeyPair = { privateKeyPem: encryptionSecret.value, publicKeyPem: exportPublicKeyToPem(createPublicKey(createPrivateKey(encryptionSecret.value))) }`. Add the imports at the top of the file if not already present.
   - Lines 414–420 (`get-database-secrets`, geocoding branch): replace `JSON.parse(geocodingSecret.value); secrets.geocodingApiKey = parsed.apiKey;` with `secrets.geocodingApiKey = geocodingSecret.value;`.
   - Lines 354, 395, 441, 496 (`s3-credentials` JSON parses) need no change — the format is still JSON; they already do not look at `label`.

### D. Production code — desktop frontend

6. Edit `packages/user-interface/src/components/share-database-dialog.tsx` `handleStartSend()`:
   - Lines 101–115 (`s3Credentials`): keep the `JSON.parse`. Drop `label: parsed.label` and replace with `label: entry.s3Key` so the receive-side checkbox still renders a non-empty string.
   - Lines 117–129 (`encryptionKey`): stop parsing as JSON. Treat `valueJson` as the raw private-key PEM. The frontend cannot derive the public key with `node:crypto`, so set `publicKeyPem: ""` here and rely on the receiver to derive it (see step 7). Set `label: entry.encryptionKey`.
   - Lines 131–142 (`geocodingKey`): stop parsing as JSON. Set `apiKey: valueJson` and `label: entry.geocodingKey`.

### E. Production code — share payload type

7. Edit `packages/lan-share/src/lib/lan-share-types.ts`:
   - Make `IShareEncryptionKey.publicKeyPem` optional (`publicKeyPem?: string`). This lets the desktop frontend (which does not have `node:crypto`) omit it; the receiver derives it from the private key when storing.
   - Make `IShareS3Credentials.label`, `IShareEncryptionKey.label`, `IShareGeocodingKey.label` all optional (`label?: string`). Update the `// Human-readable label` comments to note this is now derived from the secret name when not provided. (`label` is still used by `receive-database-dialog.tsx` for the import checkboxes, so the type must still allow it; leaving it optional keeps existing senders working without change.)
8. Edit `packages/user-interface/src/components/receive-database-dialog.tsx` lines 323, 332, 341: change the checkbox labels to fall back to the secret `name` when `label` is missing — `${payload.s3Credentials.label ?? payload.s3Credentials.name}` etc.

### F. Smoke test seed data — desktop

9. Edit `apps/desktop/smoke-tests/7-share-secret/test.sh` line 36: replace the seed file content with `{"name":"test-secret","type":"api-key","value":"TESTAPIKEY123"}`.
10. Edit `apps/desktop/smoke-tests/8-share-database/test.sh`:
    - Line 36 (s3-credentials seed): replace with `{"name":"test-s3-key","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"testsecret\"}"}`.
    - Line 41 (encryption-key seed): the value must be a real, parseable PEM, because step 4 now derives the public key with `createPrivateKey`. Replace the fake `"test-private"` string with a fixture PEM. Generate a small RSA-2048 PEM once using `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` and embed it in the seed file (use a python heredoc similar to test 11 to avoid escaping headaches). Format of the resulting seed file: `{"name":"test-enc-key","type":"encryption-key","value":"<RAW_PEM>"}`.

### G. Smoke test seed data — CLI

11. Edit `apps/cli/smoke-tests-lan-share.sh`:
    - Line 206 (s3-credentials): change to `'{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'`.
    - Line 209 (encryption-key): change to a raw PEM string. Same constraint as step 10 — must be a parseable PEM since the CLI `dbs send` flow goes through `resolveDatabaseSharePayload` which now derives the public key. Either inline a real generated PEM or call `openssl genpkey` from the test's setup phase and read the file.
12. Edit `apps/cli/smoke-tests/44-vault-list-shared/test.sh`:
    - Line 14 (s3-credentials): drop the `"label"` field.
    - Line 17 (api-key): change to `'AIzaFakeKey123'` (raw).

### H. Jest unit tests — update fixtures

13. Edit `packages/api/src/test/lib/resolve-storage-credentials.test.ts`:
    - Lines 215, 232, 312, 319, 339, 346 (encryption-key fixtures): change each from `value: JSON.stringify({ label, privateKeyPem, publicKeyPem })` to `value: <PEM string>`. The tests assert `result.encryptionKeyPems[0].privateKeyPem` matches the input, so use simple PEM-shaped strings such as `'-----PARAM-----'` directly. NOTE: `parseEncryptionKeyFromVaultValue` (still in `resolve-storage-credentials.ts`) calls `createPrivateKey` on the raw value when JSON parsing fails. Because the test fixture strings are not real PEMs, that call will throw. Step 14 below removes the JSON branch and step 15 below mocks `createPrivateKey`/`createPublicKey` in this test file.
    - Lines 248, 272 (api-key fixtures): change each from `JSON.stringify({ label, apiKey })` to the raw `apiKey` string. The tests assert `result.googleApiKey === <value>` which is now satisfied directly.
14. Edit `packages/api/src/lib/resolve-storage-credentials.ts` function `parseEncryptionKeyFromVaultValue` (lines 35–49): remove the JSON parsing branch entirely. The function body becomes the raw-PEM derivation: `const privateKeyObj = createPrivateKey(value); const publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj)); return { privateKeyPem: value, publicKeyPem };`. Update the doc comment above the function accordingly.
15. Edit `packages/api/src/test/lib/resolve-storage-credentials.test.ts` to mock `node:crypto`'s `createPrivateKey` / `createPublicKey` and `storage`'s `exportPublicKeyToPem` so that the test fixtures (which are not real PEMs) do not crash inside `parseEncryptionKeyFromVaultValue`. Pattern to follow:
    ```ts
    jest.mock("node:crypto", () => ({
        ...jest.requireActual("node:crypto"),
        createPrivateKey: jest.fn(() => ({})),
        createPublicKey: jest.fn(() => ({})),
    }));
    jest.mock("storage", () => ({
        ...jest.requireActual("storage"),
        exportPublicKeyToPem: jest.fn(() => "-----PUB-----"),
    }));
    ```
    Place these mocks at the top of the file, alongside the existing `jest.mock` calls. Adjust assertions on `publicKeyPem` to match the mocked return value (`'-----PUB-----'`) where they currently expect e.g. `'-----PUB-----'`, `'-----PUB1-----'`, etc. — most existing assertions are on `privateKeyPem`, so few changes should be needed.
16. Edit `packages/lan-share/src/test/lan-share-resolve.test.ts`:
    - Lines 47–56 (encryption-key vault `mockVaultGet` return): change `value` to a raw PEM string (any non-empty string will do — the existing `jest.mock("storage", …)` at line 14 already stubs `exportPublicKeyToPem` to return `"-----MOCKED PUBLIC-----"`, but `createPublicKey(createPrivateKey(value))` runs unmocked, so add a `jest.mock("node:crypto", …)` similar to step 15).
    - Lines 38–45 (s3-credentials vault return): drop the `label` field from the JSON value.
    - Lines 58–66 (api-key vault return): change `value` to the raw `apiKey` string `"geo-key-123"`.
    - Lines 81, 89, 95 (label assertions): update to expect the secret name as the label fallback (`entry.s3Key === "abc12345"`, etc.).
    - Line 134 (s3 secret share test fixture): drop `label`.
17. Edit `packages/lan-share/src/test/lan-share-import.test.ts`:
    - Line 70 (`s3Value.label`): the assertion `expect(s3Value.label).toBe("My S3")` no longer holds because the import now drops `label` from the stored vault value. Either delete that assertion or replace it with `expect(s3Value.label).toBeUndefined()`.
    - Lines 79–80 (encryption assertion): `JSON.parse(encCall[0].value)` will now throw because the value is raw PEM. Replace with `expect(encCall[0].value).toBe("-----PRIVATE-----")`.
    - Lines 87–88 (api-key assertion): `JSON.parse(geoCall[0].value)` will likewise throw. Replace with `expect(geoCall[0].value).toBe("geo-key-123")`.
    - Lines 113 and the other `value: JSON.stringify({ label: …, … })` occurrences in the rest of the file: drop `label` from each, but keep the JSON shape (since it's still s3-credentials).

### I. Documentation

18. Edit `/home/ash/projects/photosphere/photosphere.wiki/Managing-Secrets.md` line 147: the paragraph "Secrets linked to database entries are stored with an 8-character alphanumeric name (e.g. `abc12345`) that is generated automatically when you create them through `psi dbs add` or the desktop database form." is no longer true after the desktop-side change in commit `9be041a0`. Replace with text describing that the user-typed name is used directly as the vault key. (The CLI `dbs add` flow still generates an 8-char ID via `generateSharedSecretId()`; mention this distinction.)
19. Edit `packages/electron-defs/src/lib/electron-api.ts` lines 60–69: update the `ISharedSecretEntry.name` doc comment that currently reads "the 'label' field in the vault value JSON" — the label field no longer exists. Change to "the user-typed secret name; this is the same as `id` for secrets created in the new format."

## Unit Tests

- Update `packages/api/src/test/lib/resolve-storage-credentials.test.ts` (steps 13, 15) — fixtures and crypto mocks.
- Update `packages/lan-share/src/test/lan-share-resolve.test.ts` (step 16) — fixtures and crypto mock.
- Update `packages/lan-share/src/test/lan-share-import.test.ts` (step 17) — assertions about stored value shape.
- Add a new test in `packages/lan-share/src/test/lan-share-import.test.ts` named "stores encryption-key as raw PEM, not JSON-wrapped" that asserts `mockVaultSet` was called with a `value` equal to `payload.encryptionKey.privateKeyPem` (string identity, not JSON).
- Add a new test in `packages/lan-share/src/test/lan-share-import.test.ts` named "stores api-key as raw string, not JSON-wrapped" with the analogous assertion for the geocoding key.
- Add a new test in `packages/lan-share/src/test/lan-share-resolve.test.ts` named "derives publicKeyPem from raw-PEM encryption-key value" that mocks the vault to return `value: "-----RAW PRIVATE-----"` and asserts the resolver returns the mocked `exportPublicKeyToPem` output as `publicKeyPem`.
- Add a new test in `packages/api/src/test/lib/resolve-storage-credentials.test.ts` named "geocoding vault entry stored as raw string" that mocks the vault to return `value: "geo-key-456"` and asserts `result.googleApiKey === "geo-key-456"`.
- The existing `packages/user-interface/src/test/lib/secrets-form.test.ts` already covers `applyValueJson`/`buildValueJson` for the new format — no changes expected there. Re-run it to confirm.

## Smoke Tests

- `apps/desktop/smoke-tests/7-share-secret/test.sh` — must pass with raw `api-key` seed (step 9).
- `apps/desktop/smoke-tests/8-share-database/test.sh` — must pass with raw-PEM `encryption-key` seed and label-free `s3-credentials` seed (step 10). This is the test the user originally flagged.
- `apps/desktop/smoke-tests/11-edit-encryption-key/test.sh` — already exercises raw PEM, must still pass.
- `apps/desktop/smoke-tests/12-edit-api-key/test.sh` — already exercises raw key, must still pass.
- `apps/desktop/smoke-tests/13-edit-s3-credentials/test.sh` — already exercises label-free s3 JSON, must still pass.
- `apps/cli/smoke-tests-lan-share.sh` — full LAN share script (step 11).
- `apps/cli/smoke-tests/44-vault-list-shared/test.sh` — vault listing seed (step 12).
- No new smoke tests are required; the migration is exercised by the existing share tests.

## Verify

After implementing every step the AI agent must run, in order:

1. `bun run compile` from the repo root — must complete with zero TypeScript errors. If any error appears, fix it before proceeding.
2. `bun run test` from the repo root — must complete with zero failing Jest tests, including the new tests added in the Unit Tests section.
3. `bun run test:cli` from the repo root — runs `apps/cli/smoke-tests` and `apps/cli/smoke-tests-lan-share.sh`. Must complete with all tests passing.
4. `bun run test:electron` from the repo root — bundles the desktop app and runs every `apps/desktop/smoke-tests/*/test.sh`. Tests 7, 8, 11, 12, and 13 must pass.
5. `grep -rn 'JSON.stringify({[[:space:]]*label' apps packages` — must return no matches outside `docs/plans/done/`. (Catches any missed producer of old format.)
6. `grep -rn 'parsed\.label\|parsed\.privateKeyPem\|parsed\.publicKeyPem\|parsed\.apiKey' apps packages` — must return no matches in production source (only in `docs/plans/done/` if at all). Test code that explicitly tests legacy parsing is also acceptable, but only if the test name documents it.

## Human Verification

After the AI agent reports the plan complete, a human can confirm by:

1. Run `bun run dev` and click **Add Secret → Encryption key**, paste any RSA private-key PEM, save. Open the vault file under `~/.config/photosphere/vault/<name>.json` and confirm the `value` field is the raw PEM text (not a JSON-wrapped object).
2. Repeat for an API key — confirm the `value` field is the raw key string.
3. Repeat for an S3 credential — confirm the `value` field is JSON with no `label` key.
4. From the secrets page, click **Edit** on the encryption key and **Save** without changing anything — the value should round-trip identically (the bug 9be041a0 fixed).
5. Run a desktop **Share Database** flow end-to-end between two app instances; confirm the receiver's vault contains a raw PEM and a raw API key, not JSON-wrapped values.
6. Run `psi dbs add` from the CLI; choose **Create new** for an encryption key and an API key; confirm the resulting vault files store raw values.

## Notes

- Because the project rule states "backward compatibility is not required", no migration code is added to read OLD-format vault entries. Users with vaults written before commit `9be041a0` will see encryption/geocoding lookup failures until they re-add those secrets; the desktop edit flow already crashes on those entries today (the very bug being fixed), so the user impact does not change.
- The desktop frontend (`share-database-dialog.tsx`) cannot derive the public key from a private key inside the renderer (no `node:crypto`). The chosen approach is to send `publicKeyPem` as `""` from the frontend share path and have the receiver derive it during `importDatabasePayload` (step 3). This keeps the IPC surface small and avoids adding a new "derive-public-key" handler. If a future feature needs the public key in the renderer, that handler can be added then.
- The CLI `createSharedSecret()` for `s3-credentials` still asks for a label prompt, but only uses it for the success log line. We retain the prompt (deleting it would be a UX change beyond scope), but we remove the storage of `label` to align with the new format.
- The smoke-test PEM fixture (steps 10 and 11) must be a real PEM because step 4 derives the public key with `createPrivateKey`. A throwaway 2048-bit key is fine — it will live in the repo and is not used to encrypt anything real.
- `IShareS3Credentials.label`, `IShareEncryptionKey.label`, and `IShareGeocodingKey.label` are kept as optional fields (rather than removed) because the receive-side dialog uses them for display. This avoids a wider refactor and lets future senders supply a friendlier label if desired.
- `pickOrCreateSecret()` in `dbs.ts` no longer attempts to parse the old `label` field — display is just the secret name now. This is a small UX regression (CLI users see e.g. `geo7uw3a` instead of `My Geocoding Key` in the picker) but matches the desktop UX and is consistent with the new storage model. Out of scope for this plan: redesigning the CLI picker to support friendlier names.
