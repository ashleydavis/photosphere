# CLI Manual Test: Empty Plaintext Vault Shows "No secrets"

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets list` reports an empty vault.

## Prep

Move into the CLI source directory and point the CLI at empty config and vault directories:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

Expected: no output.

## Test

### 1. List secrets

```bash
bun run start -- secrets list
```

Expected:
- Output includes `No secrets`.

## Check

The list output in step 1 is the check.
