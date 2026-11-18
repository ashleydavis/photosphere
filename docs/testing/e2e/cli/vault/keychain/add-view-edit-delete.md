# CLI Manual Test: Keychain Vault Add / View / Edit / Delete / List Cycle

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the OS keychain backend supports the same `secrets` subcommands as
the plaintext backend.

## Prep

From the repo root, build the CLI, put it on the PATH, switch to the keychain backend with an isolated config, and clear any leftover test secrets from previous runs. The keychain is OS-global, so secret names collide across test runs: this test cleans up at the start and at the end (step 5).

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-keychain-add-view-edit-delete
mkdir -p /tmp/psi-cli-vault-keychain-add-view-edit-delete/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-keychain-add-view-edit-delete/config
export PHOTOSPHERE_STATE_DIR=/tmp/psi-cli-vault-keychain-add-view-edit-delete/config
export PHOTOSPHERE_VAULT_TYPE=keychain
for name in keychain-test-secret view-keychain edit-keychain renamed-keychain keep-keychain delete-keychain; do
    psi secrets remove --name "$name" --yes 2>/dev/null || true
done
```

Expected:
- No errors that would prevent later steps from running.

## Test

### 1. Add a secret

```bash
psi secrets add --yes --name keychain-test-secret --type plain --value hello123
```

Expected:
- The command exits successfully.

---

### 2. List secrets and confirm it appears

```bash
psi secrets list
```

Expected:
- Output contains `keychain-test-secret`.

---

### 3. View the secret

```bash
psi secrets view --name keychain-test-secret --yes
```

Expected:
- Output contains `hello123`.

---

### 4. Edit the secret value

```bash
psi secrets edit --name keychain-test-secret --yes --value updated123
psi secrets view --name keychain-test-secret --yes
```

Expected:
- Second command's output contains `updated123`.

## Check

### 5. Delete the secret and confirm it is gone

```bash
psi secrets remove --name keychain-test-secret --yes
psi secrets list
```

Expected:
- Output of `secrets list` does not contain `keychain-test-secret`.
