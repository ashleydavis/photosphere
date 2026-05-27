# CLI Manual Test: Adding a Secret With a Duplicate Name Fails

Test that adding a second secret with the same name as an existing one fails
and does not overwrite the original.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Point the CLI at empty config and vault directories

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

---

### 2. Add a secret the first time

```bash
bun run start -- secrets add --yes --name dup-secret --type plain --value first
```

Expected:
- The command exits successfully.

---

### 3. Attempt to add a second secret with the same name

```bash
bun run start -- secrets add --yes --name dup-secret --type plain --value second
```

Expected:
- The command exits with a non-zero status.
- The error message contains `already exists`.

---

### 4. Confirm the original secret is intact

```bash
bun run start -- secrets view --name dup-secret --yes
```

Expected:
- The value shown is `first` (not `second`).
