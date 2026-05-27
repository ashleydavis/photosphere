# CLI Manual Test: Keychain Vault Lists Multiple Secrets

Test that several secrets stored in the OS keychain all appear in `secrets
list`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Switch to the keychain backend with an isolated config

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_TYPE=keychain
```

---

### 2. Clear any leftover test secrets

```bash
for name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
    bun run start -- secrets remove --name "$name" --yes 2>/dev/null || true
done
```

---

### 3. Add three secrets of different types

```bash
bun run start -- secrets add --yes --name list-multi-secret-a --type plain --value value-a
bun run start -- secrets add --yes --name list-multi-secret-b --type api-key --value value-b
bun run start -- secrets add --yes --name list-multi-secret-c --type s3-credentials --value value-c
```

Expected:
- All three commands exit successfully.

---

### 4. List secrets

```bash
bun run start -- secrets list
```

Expected output contains all three names:
- `list-multi-secret-a`.
- `list-multi-secret-b`.
- `list-multi-secret-c`.

---

### 5. Clean up

```bash
for name in list-multi-secret-a list-multi-secret-b list-multi-secret-c; do
    bun run start -- secrets remove --name "$name" --yes
done
```
