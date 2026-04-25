# Plan: OS Keychain Vault

## Context

Secrets are currently stored as plaintext JSON files under `~/.config/photosphere/vault/`. The user wants them stored in the OS keychain (macOS Keychain, Windows Credential Vault, Linux libsecret) for proper security. Both the CLI (`apps/cli`) and Electron desktop app (`apps/desktop`) use vault. The `vault` workspace package already defines a clean `IVault` abstraction and a factory function `getVault(type)`.

**Vault type selection:** Controlled via `PHOTOSPHERE_VAULT_TYPE` env var — `"keychain"` (default) or `"plaintext"`. Future vault types (`"1password"`, `"bitwarden"`) would just be additional `IVault` implementations; the factory supports any string type.

**Constraint:** No native NAPI modules — must work inside a Bun compiled single-file executable (CLI) and an Electron bundle (desktop). Solution: shell out to OS-native keychain CLI tools.

## OS Keychain CLIs

Three separate vault classes, one per platform. `getVault("keychain")` selects the right one via `process.platform`.

| Platform | Class | Tool | Notes |
|----------|-------|------|-------|
| macOS | `MacOSKeychainVault` | `/usr/bin/security` | Ships with every macOS install |
| Linux | `LinuxKeychainVault` | `secret-tool` | Talks to any Secret Service API daemon (GNOME Keyring, KWallet, etc.); part of `libsecret-tools` |
| Windows | `WindowsKeychainVault` | PowerShell + `Windows.Security.Credentials.PasswordVault` | Available on Windows 8+ |

Each class has no platform conditionals inside its methods — all branching is in the factory. Each class is small and focused on its one tool.

On first use, each class checks the required tool is available and reports it:

**macOS:** `/usr/bin/security` exists at a fixed path; no version flag. Log `"Using macOS Keychain via /usr/bin/security"`.

**Linux:** Run `secret-tool --version`. Log the version. Throw a clear error if not found, suggesting `sudo apt install libsecret-tools`.

**Windows:** Run `$PSVersionTable.PSVersion` via PowerShell. Log `"Using Windows Credential Vault via PowerShell <version>"`.

## Key Naming — `psi-` Prefix

OS keychains identify each entry with two fields: **service** (always `"photosphere"`) and **account** (the credential identifier — "account" is keychain terminology for "username", but we use it to hold the secret's name).

Every secret name stored in the keychain is prefixed with `psi-` (e.g. `psi-shared:s3test01`). Added automatically on write, stripped on read — the user never sees it. Makes photosphere entries clearly identifiable in the OS keychain UI.

Private constant `KEYCHAIN_PREFIX = "psi-"` with two helpers:
- `toKeychainName(name: string): string` — prepends prefix
- `fromKeychainName(keychainName: string): string` — strips prefix

## Listing

- **Linux** — `secret-tool search --all service photosphere` returns all entries natively; parse `attribute.account` lines, strip prefix.
- **Windows** — `$vault.FindAllByResource('photosphere')` returns all entries natively; strip prefix from each `UserName`.
- **macOS** — no native enumeration. Maintain a plaintext index file at `~/.config/photosphere/vault-index.json` (configurable via `PHOTOSPHERE_CONFIG_DIR`) storing unprefixed names: `{ "names": ["shared:s3test01"] }`.

Named interface: `IVaultIndex { names: string[] }`

## Files to Change

Shared named interfaces (in a new `packages/vault/src/lib/keychain-types.ts`):
- `IKeychainPayload { type: string; value: string }` — JSON envelope stored as the keychain "password"
- `IVaultIndex { names: string[] }` — macOS index file

Shared helpers (same file or `keychain-utils.ts`):
- `KEYCHAIN_PREFIX`, `toKeychainName()`, `fromKeychainName()`
- `runCommand(args: string[]): Promise<string>` — spawns a process, resolves stdout, rejects on non-zero exit

### 1a. NEW `packages/vault/src/lib/macos-keychain-vault.ts`
`MacOSKeychainVault implements IVault`. Uses `/usr/bin/security`.

Commands:
```
# set:    security add-generic-password -U -s photosphere -a psi-<name> -w <json>
# get:    security find-generic-password -s photosphere -a psi-<name> -w
# delete: security delete-generic-password -s photosphere -a psi-<name>
# list:   index file (no native enumeration)
```

Maintains `vault-index.json` under `PHOTOSPHERE_CONFIG_DIR`. Index updated on `set` and `delete`.

### 1b. NEW `packages/vault/src/lib/linux-keychain-vault.ts`
`LinuxKeychainVault implements IVault`. Uses `secret-tool` (talks to any Secret Service API daemon).

Commands:
```
# set:    echo -n <json> | secret-tool store --label=psi-<name> service photosphere account psi-<name>
# get:    secret-tool lookup service photosphere account psi-<name>
# delete: secret-tool clear service photosphere account psi-<name>
# list:   secret-tool search --all service photosphere  (parse attribute.account lines, strip prefix)
```

No index file needed — native listing available.

### 1c. NEW `packages/vault/src/lib/windows-keychain-vault.ts`
`WindowsKeychainVault implements IVault`. Uses PowerShell `Windows.Security.Credentials.PasswordVault`.

Commands:
```powershell
# set:    New-Object PasswordVault; Add PasswordCredential('photosphere','psi-<name>','<json>')
# get:    Retrieve('photosphere','psi-<name>'); RetrievePassword(); Write-Output Password
# delete: Retrieve then Remove
# list:   FindAllByResource('photosphere'); foreach RetrievePassword; Write-Output UserName
```

No index file needed — native listing available.

### 2. `packages/vault/src/lib/get-vault.ts`
- Export `getDefaultVaultType()`: returns `process.env.PHOTOSPHERE_VAULT_TYPE ?? "keychain"`
- Add `"keychain"` branch in `instantiateVault()` that selects `MacOSKeychainVault`, `LinuxKeychainVault`, or `WindowsKeychainVault` based on `process.platform`. Throws a clear error if run on an unsupported platform.
- Update error message to list both supported types

### 3. `packages/vault/src/index.ts`
```typescript
export * from "./lib/keychain-types";
export * from "./lib/macos-keychain-vault";
export * from "./lib/linux-keychain-vault";
export * from "./lib/windows-keychain-vault";
```

### 4. `apps/cli/src/**` — 24 call sites across 6 files
Replace every `getVault("plaintext")` with `getVault(getDefaultVaultType())`, add `getDefaultVaultType` to vault import.

Files: `cmd/secrets.ts`, `cmd/dbs.ts`, `cmd/encrypt.ts`, `cmd/replicate.ts`, `lib/config.ts`, `lib/init-cmd.ts`

### 5. `apps/desktop/src/main.ts` — 5 call sites (lines ~241, 247, 253, 259, 304)
Same replacement. Update vault import on line 21.

### 6. `apps/cli/smoke-tests.sh`
Add near top with other `PHOTOSPHERE_*` env vars:
```bash
export PHOTOSPHERE_VAULT_TYPE="plaintext"
```
All existing tests continue to work unchanged — `seed_vault_secret()` and file-based assertions are unaffected.

### 7. `apps/cli/smoke-tests-encrypted.sh`
Add near top with other `PHOTOSPHERE_*` env vars:
```bash
export PHOTOSPHERE_VAULT_TYPE="plaintext"
```
This protects all existing encrypted tests (they use `--generate-key` which stores keys in the vault).

Then add new keychain-specific test functions that explicitly set `PHOTOSPHERE_VAULT_TYPE=keychain` within the test:
- `test_keychain_vault_add` — add a secret, verify it appears in `secrets list`
- `test_keychain_vault_view` — add a secret, verify `secrets view` returns the correct value
- `test_keychain_vault_edit` — add a secret, edit its value, verify updated value
- `test_keychain_vault_delete` — add a secret, delete it, verify it is gone from `secrets list`

Each test saves/restores `PHOTOSPHERE_VAULT_TYPE` around its body and cleans up keychain entries on exit.

### 8. `apps/cli/smoke-tests-lan-share.sh`
Add `export PHOTOSPHERE_VAULT_TYPE="plaintext"` near its env var setup.

### 9. `.github/workflows/release.yml` — `smoke-test-encrypted` job
The existing job runs on `ubuntu-latest` and already runs `smoke-tests-encrypted.sh`. Add two steps before the test step:

```yaml
- name: Install keychain tools (Linux)
  run: |
    sudo apt-get install -y libsecret-tools gnome-keyring

- name: Start keyring daemon (Linux)
  run: |
    eval $(gnome-keyring-daemon --unlock --components=secrets <<< "ci-test-password")
    echo "GNOME_KEYRING_CONTROL=$GNOME_KEYRING_CONTROL" >> $GITHUB_ENV
    echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >> $GITHUB_ENV
```

The macOS and Windows build jobs (`build-macos-x64`, `build-macos-arm64`, `build-windows`) already run `smoke-tests.sh --binary`, which has `PHOTOSPHERE_VAULT_TYPE=plaintext` — no changes needed there. The keychain smoke tests live in `smoke-tests-encrypted.sh` which is only run in the `smoke-test-encrypted` job (Linux only in CI). macOS and Windows keychain coverage comes from manual testing and future dedicated jobs.

## Unit Tests

Three test files, one per vault class. Each mocks `runCommand` with an in-memory map. `MacOSKeychainVaultTest` also points `PHOTOSPHERE_CONFIG_DIR` at a temp dir for the index file.

**`packages/vault/src/test/macos-keychain-vault.test.ts`**
**`packages/vault/src/test/linux-keychain-vault.test.ts`**
**`packages/vault/src/test/windows-keychain-vault.test.ts`**

Each covers:
- `get` returns `undefined` for missing secret
- `get` returns secret after `set`
- `set` stores name, type, and value correctly
- `set` does not duplicate name in index on overwrite (macOS only)
- `list` returns empty array when no secrets exist
- `list` returns all stored secrets
- `delete` removes secret (subsequent `get` returns `undefined`)
- `delete` removes name from index (macOS only)
- `delete` does nothing when secret does not exist
- `psi-` prefix is added on write and stripped on read
- handles names with special characters (colons, slashes)

### Extend `packages/vault/src/test/get-vault.test.ts`
- `getDefaultVaultType()` returns `"keychain"` when env var is unset
- `getDefaultVaultType()` returns `"plaintext"` when `PHOTOSPHERE_VAULT_TYPE=plaintext`
- `getVault("keychain")` returns the correct platform vault instance

## Documentation

Update the wiki to document:
- The two vault types (`keychain` and `plaintext`) and when to use each
- The `PHOTOSPHERE_VAULT_TYPE` env var
- Platform requirements for keychain (macOS: built-in, Linux: `libsecret-tools`, Windows: built-in)
- How to identify photosphere entries in the OS keychain UI (look for entries prefixed with `psi-`)

## Verification

1. `bun run compile` — TypeScript compiles cleanly
2. `bun run test` in `packages/vault` — all unit tests pass
3. `./apps/cli/smoke-tests.sh` — all existing plaintext smoke tests pass
4. `./apps/cli/smoke-tests-encrypted.sh` — existing encrypted tests pass, new keychain tests pass
5. Manual: `bun run start -- secrets add` in `apps/cli` (no env override) → secret appears in OS keychain app
6. `bun run bundle` in `apps/desktop` — Electron bundle builds cleanly
