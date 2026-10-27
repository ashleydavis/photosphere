# CLI Manual Test: Add a Secret to the Plaintext Vault

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets add` writes a secret that subsequently appears in
`secrets list`.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-add-secret
mkdir -p /tmp/psi-cli-vault-plaintext-add-secret/config /tmp/psi-cli-vault-plaintext-add-secret/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-add-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-add-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

Expected: no output.

## Test

### 1. Add a plain secret via CLI flags

```bash
psi secrets add --yes --name test-secret --type plain --value hello123
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm it is in the vault file and the list

```bash
jq 'keys' /tmp/psi-cli-vault-plaintext-add-secret/vault/vault.json
psi secrets list
```

Expected:
- `/tmp/psi-cli-vault-plaintext-add-secret/vault/vault.json` holds a `test-secret` key.
- The list output contains `test-secret`.
