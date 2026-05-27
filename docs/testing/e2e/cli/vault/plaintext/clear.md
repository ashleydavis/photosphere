# CLI Manual Test: `secrets clear --yes` Removes All

Test that `secrets clear --yes` empties the vault entirely.

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

### 2. Seed multiple secrets

```bash
cat > /tmp/psi-test/vault/clear-secret-one.json <<'EOF'
{"name":"clear-secret-one","type":"plain","value":"value-one"}
EOF
cat > /tmp/psi-test/vault/clear-secret-two.json <<'EOF'
{"name":"clear-secret-two","type":"plain","value":"value-two"}
EOF
```

---

### 3. Clear all secrets

```bash
bun run start -- secrets clear --yes
```

Expected:
- The command exits successfully.

---

### 4. Confirm the vault is empty

```bash
bun run start -- secrets list
```

Expected:
- Output contains `No secrets`.
- Output does not contain `clear-secret-one` or `clear-secret-two`.
