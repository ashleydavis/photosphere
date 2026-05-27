# CLI Manual Test: Delete a Plaintext Vault Secret

Test that `secrets remove --yes` deletes a secret while leaving the rest of
the vault intact.

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

### 2. Seed two secrets

```bash
cat > /tmp/psi-test/vault/keep-secret.json <<'EOF'
{"name":"keep-secret","type":"plain","value":"keep-me"}
EOF
cat > /tmp/psi-test/vault/delete-secret.json <<'EOF'
{"name":"delete-secret","type":"plain","value":"delete-me"}
EOF
```

---

### 3. Delete one of them

```bash
bun run start -- secrets remove --name delete-secret --yes
```

Expected:
- The command exits successfully.

---

### 4. Confirm the list

```bash
bun run start -- secrets list
```

Expected:
- Output contains `keep-secret`.
- Output does not contain `delete-secret`.
- `/tmp/psi-test/vault/delete-secret.json` no longer exists.
