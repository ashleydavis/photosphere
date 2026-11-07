# CLI Manual Test: Adding a Secret With a Duplicate Name Fails

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that adding a second secret with the same name as an existing one fails
and does not overwrite the original.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then add a secret the first time:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-add-duplicate-fails
mkdir -p /tmp/psi-cli-vault-plaintext-add-duplicate-fails/config /tmp/psi-cli-vault-plaintext-add-duplicate-fails/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-add-duplicate-fails/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-add-duplicate-fails/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi secrets add --yes --name dup-secret --type plain --value first
```

Expected:
- The `secrets add` exits successfully.

## Test

### 1. Attempt to add a second secret with the same name

```bash
psi secrets add --yes --name dup-secret --type plain --value second
```

Expected:
- The command exits with a non-zero status.
- The error message contains `already exists`.

## Check

### 2. Confirm the original secret is intact

```bash
psi secrets view --name dup-secret --yes
```

Expected:
- The value shown is `first` (not `second`).
