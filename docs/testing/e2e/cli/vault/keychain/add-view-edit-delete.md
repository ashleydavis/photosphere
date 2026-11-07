# CLI Manual Test: Keychain Vault Add / View / Edit / Delete / List Cycle

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the OS keychain backend supports the same `secrets` subcommands as
the plaintext backend.

## Prerequisites

From the repo root, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

Each step opts the CLI into the OS-keychain vault by setting
`PHOTOSPHERE_VAULT_TYPE=keychain`. The keychain is OS-global, so secret
names collide across test runs. Clean up at the start and end (step 7) of
this walkthrough.

## Steps

### 1. Switch to the keychain backend with an isolated config

```bash
rm -rf /tmp/psi-cli-vault-keychain-add-view-edit-delete
mkdir -p /tmp/psi-cli-vault-keychain-add-view-edit-delete/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-keychain-add-view-edit-delete/config
export PHOTOSPHERE_VAULT_TYPE=keychain
```

---

### 2. Clear any leftover test secrets from previous runs

```bash
for name in keychain-test-secret view-keychain edit-keychain renamed-keychain keep-keychain delete-keychain; do
    psi secrets remove --name "$name" --yes 2>/dev/null || true
done
```

Expected:
- No errors that would prevent later steps from running.

---

### 3. Add a secret

```bash
psi secrets add --yes --name keychain-test-secret --type plain --value hello123
```

Expected:
- The command exits successfully.

---

### 4. List secrets and confirm it appears

```bash
psi secrets list
```

Expected:
- Output contains `keychain-test-secret`.

---

### 5. View the secret

```bash
psi secrets view --name keychain-test-secret --yes
```

Expected:
- Output contains `hello123`.

---

### 6. Edit the secret value

```bash
psi secrets edit --name keychain-test-secret --yes --value updated123
psi secrets view --name keychain-test-secret --yes
```

Expected:
- Second command's output contains `updated123`.

---

### 7. Delete the secret and confirm it is gone

```bash
psi secrets remove --name keychain-test-secret --yes
psi secrets list
```

Expected:
- Output of `secrets list` does not contain `keychain-test-secret`.
