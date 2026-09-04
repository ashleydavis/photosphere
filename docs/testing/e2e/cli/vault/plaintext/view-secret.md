# CLI Manual Test: View a Plaintext Vault Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets view --yes` prints the full secret value.

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
cat > /tmp/psi-test/vault/vault.json <<'EOF'
{"view-secret":{"name":"view-secret","type":"plain","value":"my-secret-value"}}
EOF
```

---

### 3. View the secret

```bash
bun run start -- secrets view --name view-secret --yes
```

Expected output contains all of:
- `view-secret` (the name).
- `plain` (the type).
- `my-secret-value` (the value).
