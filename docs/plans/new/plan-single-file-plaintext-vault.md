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

### Step 3: Update the shell seeding helpers to write one file

Every caller now builds its JSON with `jq` inline rather than through a helper script, so there is no helper to change: the change is to what those `jq` expressions write and where.

`apps/desktop/smoke-tests/lib/common.sh` holds `write_vault_secret` and `write_vault_secret_from_file`, which the Electron tests call. Change both so the output path is the vault file rather than a per-secret file, and so they merge into it: read the existing document when present, set the entry keyed by the secret's name, and write the whole thing back. `jq` does the merge in one pass with `--argjson` over the existing content, or with `--slurpfile` when the file may be absent. An absent file starts from `{}`. A file that does not parse must stop the test, not be treated as empty.

The same change is needed at the call sites that inline the expression rather than using those functions:

- `apps/cli/smoke-tests/lib/common.sh`, `seed_vault_secret`
- `apps/cli/smoke-tests-key-chain/lib/common.sh`, `seed_vault_secret`
- `apps/cli/smoke-tests-lan-share.sh`
- `cli-desktop-lan-share-smoke-tests.sh`

In the two `seed_vault_secret` copies, drop the `url_encode_segment` call and the `encoded_name` variable with it: the name goes into a JSON key, which needs no encoding. The `chmod 600` moves from the per-secret file to the vault file.

The two `lib/common.sh` copies are near-identical. Diff them first and make the same change in both.

`cli-desktop-lan-share-smoke-tests.sh` also has a second function, `seed_secret`, that sed-escapes into a heredoc and never used a helper. It writes per-secret files too and must be changed or removed as part of this step. It already emits invalid JSON for any value containing a newline, so replacing it with the same `jq` expression fixes that at the same time.

### Step 4: Update the smoke tests that read vault files

These read a per-secret file by path and must read the named entry out of `vault.json` instead. Each already uses `jq`, so the change is to the filter: `jq -j '.value' <file>` becomes `jq -j '.["<name>"].value' <file>`, with the name passed through `--arg` rather than spliced into the filter.

- `apps/desktop/smoke-tests/11-edit-encryption-key/test.sh` (two calls, `value` and `type`)
- `apps/desktop/smoke-tests/12-edit-api-key/test.sh`
- `apps/desktop/smoke-tests/13-edit-s3-credentials/test.sh` (five calls)
- `apps/desktop/smoke-tests/14-rename-secret/test.sh`
- `apps/cli/smoke-tests/49-dbs-resolve-by-name/test.sh`
- `apps/cli/smoke-tests/50-dbs-resolve-by-path/test.sh`

Keep `-j` on the value reads. It gives raw output with no trailing newline, which is what test 11's `cmp` against a PEM depends on.

Test 13 checks that a field is absent with `jq -e 'has("...")'`. That becomes a check on the nested object and must keep returning a non-zero exit when the field is missing.

`apps/desktop/smoke-tests/22-edit-database-origin/test.sh` reads a database config, not a vault file. Leave it alone.

### Step 5: Delete `scripts/json-encode.ts`

- Edit `apps/smoke-tests/tests/32-encrypted-database/test.sh` line 82. Replace `bun "$REPO_DIR/scripts/json-encode.ts" --string "$TMP_DIR/key.pem"` with `jq -Rs . < "$TMP_DIR/key.pem"`. Update the comment above it, which currently says the payload is built with `JSON.stringify`.

`--url-segment`, the helper's other mode, has no caller once step 3 removes the filename encoding, so nothing else needs replacing before the file goes.
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

Nothing outside `packages/vault` gains a unit test. The seeding and reading now happen in shell, which this repository does not unit-test, and the smoke suites below are what exercise them.

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
- `jq` is not bundled with Git for Windows, and the repository's only pre-existing use of it (`.github/workflows/release.yml:1695`) is explicitly guarded with `if: runner.os != 'Windows'`. Whether `mise` can supply `jq` on Windows has not been checked. This plan does not widen that exposure: the CLI and Electron suites already depend on `jq` for exactly these files.
- Written before the shell-helper review landed, and revised after. `read-json-field.ts` and `write-vault-secret.ts` no longer exist: their callers now build and read this JSON with `jq` inline, which is why steps 3 and 4 change `jq` filters rather than a helper's arguments. `json-encode.ts` is the one helper left standing that this plan removes.
- `mise.toml` already pins `jq`, added when the field reads moved to it, so nothing new has to be declared.
- No migration is written, per the repository's stance that backward compatibility is not required. An existing per-secret vault directory becomes invisible: the secrets are still on disk but the app will not read them. If that matters for a real user's vault, say so, because it is a data-loss-shaped change from their point of view even though nothing is deleted.
