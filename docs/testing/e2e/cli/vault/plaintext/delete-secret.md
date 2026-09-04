# CLI Manual Test: Delete a Plaintext Vault Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

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
cat > /tmp/psi-test/vault/vault.json <<'EOF'
{
  "keep-secret": {"name":"keep-secret","type":"plain","value":"keep-me"},
  "delete-secret": {"name":"delete-secret","type":"plain","value":"delete-me"}
}
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
- `/tmp/psi-test/vault/vault.json` no longer holds a `delete-secret` key, and still holds `keep-secret`.
