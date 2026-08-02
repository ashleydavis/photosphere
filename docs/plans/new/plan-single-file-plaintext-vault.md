# Store the plaintext vault as one file and delete json-encode.ts

## Overview

`PlaintextVault` stores every secret in its own file, named after the secret with the name percent-encoded so it is filename-safe (`encodeSecretName` in `packages/vault/src/lib/plaintext-vault.ts`). That encoding is the only reason `scripts/json-encode.ts --url-segment` exists: the smoke tests seed secrets by writing those files directly, so they have to reproduce the app's filename rule, and they carry a second implementation of it to do so. Two copies of one rule, and a whole helper script, to solve a problem the storage format created.

Storing all secrets in a single `vault.json` keyed by name removes the problem rather than encoding around it. A secret name then lives in a JSON key, where a colon, slash or unicode character needs no special treatment. The tests seed by writing one JSON document instead of a directory of files, and neither the app nor the tests need a name-to-filename rule at all.

`scripts/json-encode.ts` is deleted as part of this. Its `--url-segment` mode has no remaining caller once the vault changes. Its `--string` mode has one caller, `apps/smoke-tests/tests/32-encrypted-database/test.sh`, which is moved to `jq -Rs .`.

Backward compatibility is not required, so no migration is written: an existing per-secret vault directory is simply not read.

## Issues

## Steps

### Step 1: Rewrite `PlaintextVault` to store one file

Edit `packages/vault/src/lib/plaintext-vault.ts`.

- Delete `encodeSecretName`, `decodeSecretName` and `secretFilePath`.
- Replace `SECRET_FILE_EXTENSION` with a `VAULT_FILE_NAME` constant of `"vault.json"`.
- Add a private `vaultFilePath` field, or a private method returning `path.join(this.vaultDir, VAULT_FILE_NAME)`.
- Define a named interface for the file's shape. Do not use an inline anonymous object type. The file is a JSON object whose keys are secret names and whose values are `ISecret`.
- Add a private `readAll(): Promise<IVaultFile>` that reads and parses the file, returning an empty object when the file does not exist (`ENOENT`). A file that exists but does not parse must throw, not be treated as empty.
- Add a private `writeAll(contents: IVaultFile): Promise<void>` that calls `ensureDir`, writes the file with `mode: FILE_MODE`, then `chmod` to `FILE_MODE` as the current `set` does.
- `get(name)`: read all, return the entry for `name`, or `undefined`.
- `set(secret)`: read all, assign `secret` under `secret.name`, write all.
- `list()`: read all, return `Object.values(...)`.
- `delete(name)`: read all, remove the key, write all. Do nothing when absent.
- `exists()`: change from testing the directory to testing the vault file with `fsSync.existsSync`.
- Update the class comment block: it currently says each secret is written to its own percent-encoded file. Update the `DEFAULT_VAULT_DIR` and `FILE_MODE` comments only if they become inaccurate.

Complete when `bun run compile` passes and the tests from Step 2 pass.

### Step 2: Update the `PlaintextVault` unit tests

Edit `packages/vault/src/test/plaintext-vault.test.ts` (211 lines, 28 tests).

- The `get`, `set`, `list`, `delete` and `secret names with special characters` groups should keep their existing assertions unchanged. They assert behaviour through the `IVault` interface and must pass against the new storage without being rewritten. If one needs changing, that is a behaviour change and must be called out rather than quietly accepted.
- `list` group: `"ignores files without the .json extension"` no longer describes anything real. Replace it with a test that a stray non-vault file in the vault directory is ignored, or delete it if the new implementation makes that vacuous.
- `file permissions` group: `"secret file is created with owner-only permissions (0o600)"` must now assert the mode of `vault.json`.
- `exists` group: both tests must still pass. `"returns false before any secrets are stored"` now means the vault file is absent.
- Add a test that `set` on a vault holding other secrets preserves them, since `set` is now a read-modify-write and could drop them.
- Add a test that a malformed `vault.json` causes `get` and `list` to throw rather than silently returning nothing.

Watch each new test fail before accepting it.

### Step 3: Update `scripts/write-vault-secret.ts` to write into the single file

Edit `scripts/write-vault-secret.ts`.

- Its `--file` argument currently names a per-secret file. Change the contract so it names the vault file (`vault.json`), and the helper merges the named secret into that file rather than overwriting it.
- It must read the existing file when present, add or replace the entry keyed by name, and write the whole document back. An absent file starts from an empty object. A malformed file throws.
- Update its comment block and documented argument list to match.
- Keep the helper. Whether it survives at all is helper 8's separate question and is not settled here.

### Step 4: Update the shell seeding helpers

Edit these, all of which build a per-secret path today:

- `apps/cli/smoke-tests/lib/common.sh`, `seed_vault_secret` (around line 754)
- `apps/cli/smoke-tests-key-chain/lib/common.sh`, `seed_vault_secret` (around line 756)
- `apps/cli/smoke-tests-lan-share.sh` (around line 230)
- `cli-desktop-lan-share-smoke-tests.sh` (around line 107)
- `apps/desktop/smoke-tests/` test scripts that call `write-vault-secret.ts` directly: tests 8, 11, 12, 13, 14, 15

In each: drop the `json-encode.ts --url-segment` call and the `encoded_name` variable, and pass `"$PHOTOSPHERE_VAULT_DIR/vault.json"` as `--file`. The `chmod 600` on the per-secret file becomes a `chmod 600` on the vault file, or is dropped if the helper already sets the mode.

`apps/cli/smoke-tests/lib/common.sh` and `apps/cli/smoke-tests-key-chain/lib/common.sh` hold near-identical copies of `seed_vault_secret`. Diff them first and make the same change in both.

`cli-desktop-lan-share-smoke-tests.sh` also has a second function, `seed_secret` (around line 79), that sed-escapes into a heredoc and never used the helper. It writes per-secret files too and must be changed or removed as part of this step.

### Step 5: Update the smoke tests that read vault files

These read a per-secret file by path and must read the named entry out of `vault.json` instead:

- `apps/desktop/smoke-tests/11-edit-encryption-key/test.sh` lines 53 and 59
- `apps/desktop/smoke-tests/12-edit-api-key/test.sh` line 46
- `apps/desktop/smoke-tests/13-edit-s3-credentials/test.sh` (five calls via the `READ_FIELD` variable, from line 49)
- `apps/desktop/smoke-tests/14-rename-secret/test.sh` line 56
- `apps/cli/smoke-tests/49-dbs-resolve-by-name/test.sh` line 28
- `apps/cli/smoke-tests/50-dbs-resolve-by-path/test.sh` line 28

`scripts/read-json-field.ts --field value` becomes a read of the nested field. Extend `read-json-field.ts` to accept a path of keys, or add a `--secret <name>` argument, rather than adding a second helper.

`apps/desktop/smoke-tests/22-edit-database-origin/test.sh` line 59 reads a database config, not a vault file. Leave it alone.

Test 13 relies on `read-json-field.ts` exiting non-zero when a field is absent. Preserve that behaviour for the nested case.

Note: `read-json-field.ts` is helper 5's subject in a separate worktree. This plan changes its argument handling, not whether it survives.

### Step 6: Replace the last `json-encode.ts` caller and delete it

- Edit `apps/smoke-tests/tests/32-encrypted-database/test.sh` line 82. Replace `bun "$REPO_DIR/scripts/json-encode.ts" --string "$TMP_DIR/key.pem"` with `jq -Rs . < "$TMP_DIR/key.pem"`. Update the comment above it, which currently says the payload is built with `JSON.stringify`.
- Add `jq = "1.7.1"` to the `[tools]` section of `mise.toml`, so the dependency is declared rather than assumed present.
- Delete `scripts/json-encode.ts`.
- Grep the whole repository excluding `node_modules` and `.git` for `json-encode` and confirm no reference survives, including in `docs/` and `.github/workflows/`.

### Step 7: Update the documentation

- `docs/testing/README.md` line 178 describes `PHOTOSPHERE_VAULT_DIR` as "Secrets storage (plaintext mode only)". Confirm it is still accurate and adjust if it describes per-secret files anywhere.
- Grep `docs/testing/e2e/` for text describing the vault as a directory of per-secret JSON files and correct it. `docs/testing/e2e/desktop/lan-share/share-secret.md` and `docs/testing/e2e/desktop/lan-share/share-database.md` are known to describe the layout.
- `docs/destructive-command-audit.md` mentions vault handling; check whether the change affects what it records.

## Unit Tests

In `packages/vault/src/test/plaintext-vault.test.ts`:

- Every existing `get`, `set`, `list`, `delete` and special-character test must pass unchanged. They are the proof the interface behaviour did not move.
- `set` preserves other secrets already in the file.
- `set` on an absent vault file creates it.
- `get` returns `undefined` when the vault file exists but holds no such name.
- `get` and `list` throw when `vault.json` is not valid JSON.
- `list` returns an empty array when the vault file is absent.
- `delete` removes only the named secret and leaves the rest.
- `vault.json` is created with mode `0o600` and the directory with `0o700`.
- `exists()` is false with no vault file and true after a `set`.

No unit tests exist for `scripts/write-vault-secret.ts` and none are added: it is a test-support script with no test harness, and the smoke tests below are what exercise it.

## Smoke Tests

No new smoke tests. The existing suites cover every path this touches, and the point is that they keep passing:

- `bun run test:cli` (65 tests). Covers `seed_vault_secret` through every CLI test that seeds a secret, plus tests 49 and 50 which read values back.
- `bun run test:electron` (25 tests). Covers desktop tests 8, 11, 12, 13, 14, 15, which both seed and read vault files.
- `bun run test:and` on Linux. Covers mobile test 32, the last `json-encode.ts` caller.
- `bun run test:cli -- 54` and `-- 63` for a fast check of the seeding path while iterating.

Seeding correctness is not proven by the CLI suite alone: every secret name in it is already free of special characters, so those tests would pass against a broken name path. Verify separately by seeding secrets named `shared:abc123`, `quote"name` and `space and/slash`, then reading each back with `psi secrets view --name ... --raw`, and confirm a wrong name is not found.

## Verify

- `bun run compile` succeeds.
- `bun run test` passes, including the new and existing `PlaintextVault` tests.
- `bun run test:everything -- --force` passes. This is the canonical check and what the git hook runs.
- `grep -rn 'json-encode' . --exclude-dir=node_modules --exclude-dir=.git` returns nothing.
- `grep -rn 'encodeSecretName\|decodeSecretName\|secretFilePath' . --exclude-dir=node_modules --exclude-dir=.git` returns nothing.
- Seeding a secret named `shared:abc123` produces a `vault.json` holding that exact name as a key, and `psi secrets view --name 'shared:abc123' --raw` returns its value.

## Notes

- The keychain vaults (`linux-keychain-vault.ts`, `macos-keychain-vault.ts`, `windows-keychain-vault.ts`) are untouched. They never used filename encoding. `getDefaultVaultType` returns `"keychain"`, so this changes nothing a user sees by default: the plaintext vault is reached only by setting `PHOTOSPHERE_VAULT_TYPE=plaintext`, which only the smoke tests and the manual e2e docs do.
- `set` and `delete` become read-modify-write on a shared file, where before each secret was independent. Two processes writing different secrets at the same moment can now lose one. The lan-share tests run two instances, but they point at different `PHOTOSPHERE_VAULT_DIR` values, so they do not share a file. Worth knowing before anything writes concurrently to one vault.
- Adding `jq` to `mise.toml` declares it, but `jq` is not bundled with Git for Windows, and the repository's only existing `jq` use (`.github/workflows/release.yml:1695`) is explicitly guarded with `if: runner.os != 'Windows'`. Whether `mise` can supply `jq` on Windows has not been checked. Mobile test 32 does not run on Windows, so this is a latent risk rather than a live one.
- This plan overlaps three worktrees under review: helper 2 (`json-encode.ts`, deleted here instead), helper 5 (`read-json-field.ts`, whose arguments change here), and helper 8 (`write-vault-secret.ts`, whose contract changes here). Decide what happens to those worktrees before starting, or the same files get edited twice.
- No migration is written, per the repository's stance that backward compatibility is not required. An existing per-secret vault directory becomes invisible: the secrets are still on disk but the app will not read them. If that matters for a real user's vault, say so, because it is a data-loss-shaped change from their point of view even though nothing is deleted.
