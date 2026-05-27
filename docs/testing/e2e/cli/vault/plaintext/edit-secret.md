# CLI Manual Test: Edit a Plaintext Vault Secret

Test that `secrets edit` can update the value of a secret and rename it.

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

### 2. Seed a secret

```bash
cat > /tmp/psi-test/vault/edit-secret.json <<'EOF'
{"name":"edit-secret","type":"plain","value":"original-value"}
EOF
```

---

### 3. Update the value

```bash
bun run start -- secrets edit --name edit-secret --yes --value updated-value
```

---

### 4. Confirm the value updated

```bash
bun run start -- secrets view --name edit-secret --yes
```

Expected:
- Output contains `updated-value`.

---

### 5. Rename the secret

```bash
bun run start -- secrets edit --name edit-secret --yes --new-name renamed-secret
```

---

### 6. Confirm the rename

```bash
bun run start -- secrets list
```

Expected:
- Output contains `renamed-secret`.
- Output does not contain `edit-secret`.
