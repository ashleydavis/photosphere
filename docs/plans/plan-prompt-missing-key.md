# Plan: Prompt to Add Missing Encryption Key

## Overview
When a CLI command that requires an encryption key is given a key name (via `--key` or `--dest-key`) that doesn't exist in the vault, the CLI currently shows an error and exits. This plan changes that behaviour so the CLI instead prompts the user to add the key inline. For commands where the key must already exist (compare, add, sync, decrypt, hash, upgrade, etc.), the user is offered to paste a PEM or import from a file. For commands where a key can also be generated (init, encrypt, replicate with a new destination), the user is additionally offered to generate a new key.

## Issues
- [ ] None identified.

## Steps

1. **Add `promptToAddKey` to `apps/cli/src/lib/init-cmd.ts`** (after `loadKeyPairFromVault`, ~line 333)
   - Add `multiline` to the clack import on line 20.
   - Non-interactive (`nonInteractive === true`): return `undefined` — caller shows error and exits.
   - Interactive: show `select` with options: **Paste PEM**, **Import from file**, **Cancel**.
     - Paste PEM → `multiline` prompt → store via `vault.set({ name: keyName, type: 'encryption-key', value: pem })`.
     - Import from file → `text` prompt for file path → read file → store in vault.
   - Build and return `IEncryptionKeyPem` using `createPrivateKey`, `createPublicKey`, `exportPublicKeyToPem`.

2. **Add `promptToGenerateOrAddKey` to `apps/cli/src/lib/init-cmd.ts`** (directly after `promptToAddKey`)
   - Same as above, but with an additional **Generate a new key** option first.
   - Generate path: `generateKeyPair()` → store in vault → return key pair.

3. **Update `loadDatabase()` in `apps/cli/src/lib/init-cmd.ts`** (~line 664–670)
   - Replace the current `outro` + `exit(1)` block (when `--key X` is specified but `keyPems` is empty) with a call to `promptToAddKey(keyName, nonInteractive)`.
   - If the returned pair is `undefined`, fall through to `outro` + `exit(1)`.
   - Otherwise set `keyPems = [newPair]` and continue.
   - This covers: compare, add, check, find-orphans, list, remove, remove-orphans, summary, verify.

4. **Update `createDatabase()` in `apps/cli/src/lib/init-cmd.ts`** (~line 806–824)
   - Replace the `outro` + `exit(1)` block (when key not found and `generateKey` is false) with a call to `promptToGenerateOrAddKey(options.key!, nonInteractive)`.
   - If `undefined`, fall through to `outro` + `exit(1)`.

5. **Update `apps/cli/src/cmd/encrypt.ts`** (~line 88–92)
   - After `resolveKeyPems`, when `keyPems.length === 0` and `options.key` is set, call `promptToGenerateOrAddKey(options.key, nonInteractive)`.
   - Add `promptToGenerateOrAddKey` to the import from `../lib/init-cmd`.

6. **Update `apps/cli/src/cmd/replicate.ts`**
   - ~line 152–159 (existing encrypted destination, `--dest-key` specified but key not found): after `resolveKeyPems(options.destKey)`, if empty call `promptToAddKey(options.destKey!, nonInteractive)`.
   - ~line 183–197 (new destination, `--dest-key` specified): after the `generateKey` block, if `destKeyPems.length === 0` and `options.destKey` is set, call `promptToGenerateOrAddKey(options.destKey, nonInteractive)`.
   - Add `promptToAddKey`, `promptToGenerateOrAddKey` to the import from `../lib/init-cmd`.

7. **Update `apps/cli/src/cmd/decrypt.ts`** (~line 48–52)
   - After `resolveKeyPems`, when `keyPems.length === 0` and `options.key` is set, call `promptToAddKey(options.key!, nonInteractive)`.
   - Add `promptToAddKey` to the import from `../lib/init-cmd`.

8. **Update `apps/cli/src/cmd/upgrade.ts`** (~line 51–52)
   - After `resolveKeyPems`, add check: if `options.key` was set but `keyPems` is empty, call `promptToAddKey(options.key, nonInteractive)`.
   - If a pair is returned, recompute `storageOptions` and `assetStorage`.
   - Add `promptToAddKey` to the import from `../lib/init-cmd`.

9. **Update `apps/cli/src/cmd/hash.ts`** (~line 32–33)
   - After `resolveKeyPems`, add check: if `options.key` was set but `keyPems` is empty, call `promptToAddKey(options.key, options.yes ?? false)`.
   - If a pair is returned, recompute `storageOptions`.
   - Add `promptToAddKey` to the import from `../lib/init-cmd`.

10. **Update `apps/cli/src/cmd/sync.ts`** (~line 89)
    - After `resolveKeyPems(options.destKey)`, if `options.destKey` was set but `destKeyPems` is empty, call `promptToAddKey(options.destKey, nonInteractive)`.
    - Add `promptToAddKey` to the import from `../lib/init-cmd`.

## Unit Tests

Add `apps/cli/src/test/lib/init-cmd.test.ts`:

- **`promptToAddKey` — non-interactive returns `undefined`**: call with `nonInteractive = true`; expect `undefined` returned, vault not called.
- **`promptToAddKey` — user cancels**: mock `select` to return cancel symbol; expect `undefined`.
- **`promptToAddKey` — paste PEM**: mock `select` → `'paste'`, `multiline` → valid PEM string; expect vault `set` called with correct args, valid `IEncryptionKeyPem` returned.
- **`promptToAddKey` — import from file**: mock `select` → `'import'`, `text` → `/tmp/test.key`, `fs.readFile` → PEM; expect vault `set` called, valid key pair returned.
- **`promptToGenerateOrAddKey` — generate**: mock `select` → `'generate'`; expect `generateKeyPair` called, vault `set` called, valid key pair returned.
- **`promptToGenerateOrAddKey` — non-interactive returns `undefined`**: call with `nonInteractive = true`; expect `undefined`.

Use the existing mocking pattern from `packages/api/src/test/lib/resolve-storage-credentials.test.ts`:
```typescript
jest.mock('vault', () => ({ getDefaultVaultType: () => 'plaintext', getVault: () => ({ get: mockVaultGet, set: mockVaultSet }) }));
jest.mock('../lib/clack/prompts', ...);  // via moduleNameMapper in jest.config.js
```

## Smoke Tests

Add to `apps/cli/smoke-tests-encrypted.sh`:

- **`test_key_not_found_noninteractive`**: run `psi compare --key nonexistent --yes --db <db> --dest <dest>` → expect exit code 1 and `"not found"` in output (verifies non-interactive path still exits cleanly).
- **`test_key_not_found_message`**: same as above for `add`, `decrypt`, `upgrade` commands with a nonexistent `--key` and `--yes` → expect the same error pattern.

Note: Interactive "add key" prompts are not practical to smoke-test without input automation; non-interactive regression tests are sufficient.

## Verify

1. `psi compare --db <src> --dest-key nonexistent-key --dest <dest>` → prompted to add key; after pasting valid PEM the command completes successfully.
2. `psi init --key nonexistent-key --db <dir>` → prompted to generate or add; after generating the command creates an encrypted database.
3. `psi encrypt --key nonexistent-key --db <db>` → same generate-or-add prompt.
4. Cancel at any prompt → CLI exits cleanly with no stack trace.
5. `--yes` flag on any command with a missing key → exits with error message, no prompt shown (non-interactive behaviour preserved).
6. `bun run compile` passes with no TypeScript errors.
7. `bun run test` passes in `apps/cli`.

## Notes

- `loadKeyPairFromVault` stays unexported; the new functions build the key pair directly after writing to the vault (same `createPrivateKey` / `createPublicKey` / `exportPublicKeyToPem` pattern already in the file).
- `multiline` must be added to the clack import in `init-cmd.ts` (it is available from `./clack/prompts` and already used in `secrets.ts`).
- The existing `__mocks__/clack-prompts.js` mock does not include `multiline`; it will need an entry added for the unit tests to work.
