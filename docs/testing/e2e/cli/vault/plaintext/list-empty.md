# CLI Manual Test: Empty Plaintext Vault Shows "No secrets"

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets list` reports an empty vault.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-list-empty
mkdir -p /tmp/psi-cli-vault-plaintext-list-empty/config /tmp/psi-cli-vault-plaintext-list-empty/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-list-empty/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-list-empty/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

Expected: no output.

## Test

### 1. List secrets

```bash
psi secrets list
```

Expected:
- Output includes `No secrets`.

## Check

The list output in step 1 is the check.
