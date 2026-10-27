# CLI Manual Test: Keychain Vault Lists Multiple Secrets

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that several secrets stored in the OS keychain all appear in `secrets
list`.

## Prerequisites

From the repo root, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

## Steps

### 1. Switch to the keychain backend with an isolated config

```bash
rm -rf /tmp/psi-cli-vault-keychain-list-multiple
mkdir -p /tmp/psi-cli-vault-keychain-list-multiple/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-keychain-list-multiple/config
export PHOTOSPHERE_VAULT_TYPE=keychain
```

---

### 2. Clear any leftover test secrets

```bash
for name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
    psi secrets remove --name "$name" --yes 2>/dev/null || true
done
```

---

### 3. Add three secrets of different types

```bash
psi secrets add --yes --name list-multi-secret-a --type plain --value value-a
psi secrets add --yes --name list-multi-secret-b --type api-key --value value-b
psi secrets add --yes --name list-multi-secret-c --type s3-credentials --value value-c
```

Expected:
- All three commands exit successfully.

---

### 4. List secrets

```bash
psi secrets list
```

Expected output contains all three names:
- `list-multi-secret-a`.
- `list-multi-secret-b`.
- `list-multi-secret-c`.

---

### 5. Clean up

```bash
for name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
    psi secrets remove --name "$name" --yes
done
```
