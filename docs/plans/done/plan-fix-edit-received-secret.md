# Fix Edit-Received-Secret JSON Parse Crash

## Overview
In the Electron app, clicking Edit on a secret that was imported via "Receive Secret" can throw `SyntaxError: No number after minus sign in JSON at position 1` from `JSON.parse` inside `applyValueJson`. The vault entry for an `encryption-key` is a raw PEM string (the leading `-----BEGIN ...` byte sequence trips the JSON number parser at position 1), and `applyValueJson` in [packages/user-interface/src/pages/secrets/secrets-page.tsx](packages/user-interface/src/pages/secrets/secrets-page.tsx) assumes every vault value is a JSON envelope.

This plan brings the Electron edit/create code in line with the storage model documented in [Managing-Secrets.md](../../../../photosphere.wiki/Managing-Secrets.md):

- Each secret is identified by its **name** — the vault key *is* the name. There is no separate label field.
- **S3 credentials** store the credential fields (region, access key id, secret access key, optional endpoint) — no label.
- **Encryption key** stores the raw PEM private key — not JSON-wrapped. The public key is derived on demand.
- **API key** stores the raw API key string — not JSON-wrapped.

The current Electron path diverges: `addSecret` generates a random 8-char vault key and wraps every value in a `{ label, ... }` JSON envelope. This is what introduces the JSON-only assumption that the bug exploits, and it does not match the documented model.

**Constraint: keep changes minimal.** Touch only the lines required to (a) stop the crash and (b) align the Electron flow with the wiki-documented storage model. Do not change the share/receive code paths (they already pass values through unchanged) or the CLI.

## Issues
<!-- populated later by plan:check -->

## Steps
1. **Read path — `applyValueJson` in [packages/user-interface/src/pages/secrets/secrets-page.tsx](packages/user-interface/src/pages/secrets/secrets-page.tsx).** Branch on `form.type`:
   - `encryption-key` → return `{ ...form, privateKeyPem: valueJson, publicKeyPem: '' }`. The vault value is the raw PEM.
   - `api-key` → return `{ ...form, apiKey: valueJson }`. The vault value is the raw key string.
   - `s3-credentials` → `JSON.parse(valueJson)` and populate the four s3 form fields (existing logic).

2. **Write path — `buildValueJson` in [packages/user-interface/src/pages/secrets/secrets-page.tsx](packages/user-interface/src/pages/secrets/secrets-page.tsx).**
   - `encryption-key` → return `form.privateKeyPem` directly. Do not include `publicKeyPem`; the public key is derivable on demand (see `lan-share-resolve.ts:43-48`).
   - `api-key` → return `form.apiKey` directly.
   - `s3-credentials` → unchanged. The current code already produces a JSON object with only the credential fields and no label.

3. **Storage path — `addSecret` in [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx).** Replace the body with:
   ```ts
   await vault.set({ name: entry.name, type: entry.type, value });
   return { id: entry.name, name: entry.name, type: entry.type };
   ```
   Removes the random-id generation and the `JSON.stringify({ label: entry.name, ...JSON.parse(value) })` wrap. The vault key is the user-chosen name; the value is what `buildValueJson` returned (raw for `encryption-key`/`api-key`, JSON object for `s3-credentials`).

4. **Storage path — `updateSecret` in [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx).** Replace the body so it:
   - Always writes `value` as-is when provided (no `JSON.parse`, no label injection).
   - Supports rename (the wiki says "The name and values can be changed"): if `entry.id !== entry.name`, `vault.delete(entry.id)` after the `vault.set({ name: entry.name, ... })`. Order matters — set the new entry first, then delete the old, so a crash in between leaves data rather than losing it.
   - The `value === undefined` arm (label-only update) can be removed; the sole caller in `secrets-page.tsx` always passes a value, and there is no label to update independently of the value anymore.

5. **`listSecrets` in [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx).** Simplify to `return allSecrets.map(secret => ({ id: secret.name, name: secret.name, type: secret.type }));`. The current `parsed.label ?? secret.name` lookup is no longer meaningful — labels are not stored.

6. **Caller adjustment — secret-create dialogs.** [packages/user-interface/src/components/create-secret-dialog.tsx](packages/user-interface/src/components/create-secret-dialog.tsx) and [packages/user-interface/src/components/secret-quick-create-dialog.tsx](packages/user-interface/src/components/secret-quick-create-dialog.tsx) both call `platform.addSecret({ name, type }, valueJson)`. With step 3 they now use the user-typed `name` directly as the vault key. Verify uniqueness handling: if the user picks an existing name, `vault.set` will silently overwrite. Add an explicit `vault.get(name)`-then-error check inside `addSecret` so duplicates fail loudly, matching the CLI behaviour described in `Managing-Secrets.md:103` ("Secret names must be unique. If you try to add a secret with a name that is already in use, the command will error and no secret will be added.").

## Unit Tests
`applyValueJson` and `buildValueJson` are currently non-exported helpers and have no tests. To make them testable:

1. Export `applyValueJson`, `buildValueJson`, `emptyFormState`, and the `ISecretFormState` interface from `secrets-page.tsx` (named exports only).
2. Add `packages/user-interface/src/test/lib/secrets-form.test.ts`.
3. `applyValueJson` cases:
   - `s3-credentials` — populates s3 fields from a JSON value with all credential keys present.
   - `encryption-key` — raw PEM string returns `{ privateKeyPem: <raw>, publicKeyPem: '' }`.
   - `api-key` — raw key string returns `{ apiKey: <raw> }`.
4. `buildValueJson` cases:
   - `s3-credentials` — returns valid JSON with all four fields and an `endpoint` key only when `form.s3Endpoint` is non-empty (regression guard for the existing conditional).
   - `encryption-key` — returns `form.privateKeyPem` verbatim.
   - `api-key` — returns `form.apiKey` verbatim.

`addSecret`/`updateSecret`/`listSecrets` live inside React `useCallback` hooks and are not unit-testable without a renderer harness; the smoke tests below cover them end-to-end.

## Smoke Tests
Add new automated smoke-test directories under `apps/desktop/smoke-tests/` (following the existing numbered pattern, e.g. `5-add-secret/`):
- **edit-encryption-key** — seed the vault with a raw-PEM encryption-key, drive Manage Secrets → Edit, save, assert the vault still contains the raw PEM.
- **edit-api-key** — add an api-key, edit, save, assert the vault contains the raw key string with no JSON envelope.
- **edit-s3-credentials** — add an s3-credentials secret, edit a field, save, assert the vault contains JSON with the four credential fields and no `label`.
- **rename-secret** — edit a secret, change the Name field, save, assert the new vault key holds the value and the old key is gone.
- **duplicate-name** — attempt to add a secret with a name that already exists, assert the dialog reports an error and no new entry is created.

The existing `5-add-secret` and `7-share-secret` directories cover the create and share/receive flows; verify they still pass after the storage-format change.

## Verify
1. `cd packages/user-interface && bun run test -- secrets-form` — new unit tests pass.
2. `bun run compile` from repo root — TypeScript compiles cleanly.
3. `bun run test` from repo root — full test suite green.
4. `bun run smoke` from repo root — all smoke tests must pass

## Notes
- **Storage model alignment.** After this fix the Electron flow matches `Managing-Secrets.md`: vault key = name; value = credential fields JSON for `s3-credentials`, raw PEM for `encryption-key`, raw string for `api-key`; no label stored anywhere.
- **Wiki line 147 ("Shared Secrets and Database Linking").** The wiki says db-linked secrets are stored "with an 8-character alphanumeric name (e.g. `abc12345`) that is generated automatically when you create them through `psi dbs add` or the desktop database form." That auto-generation lived inside `addSecret`. After this fix it no longer does — the desktop database form (and the `create-secret-dialog`/`secret-quick-create-dialog` it uses) must generate the name itself if it wants the `abc12345` shape. **This is out of scope for this plan**; flag for a follow-up to either move the random-name generation into the database creation flow or update the wiki to reflect that user-typed names are used.
- **Why not also fix it in `share-secret-dialog.tsx` or `importSecretPayload`?** They already pass values through unchanged — that is the correct behaviour. The bug was entirely on the Electron edit/create side.
