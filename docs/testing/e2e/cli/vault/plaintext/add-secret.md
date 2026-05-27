# CLI Manual Test: Add a Secret to the Plaintext Vault

Test that `secrets add` writes a secret that subsequently appears in
`secrets list`.

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

### 2. Add a plain secret via CLI flags

```bash
bun run start -- secrets add --yes --name test-secret --type plain --value hello123
```

Expected:
- The command exits successfully.
- The file `/tmp/psi-test/vault/test-secret.json` exists.

---

### 3. Confirm it shows up in the list

```bash
bun run start -- secrets list
```

Expected:
- Output contains `test-secret`.
