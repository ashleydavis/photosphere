# CLI Manual Test: Import a PEM Key Pair

Test that `secrets import --private-key <path>` stores a PEM private key as
an `encryption-key` secret.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

`openssl` must be on `PATH`.

## Steps

### 1. Point the CLI at empty config and vault directories

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault /tmp/psi-test/keys
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

---

### 2. Generate a PEM private key

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/psi-test/keys/test-import.key
```

Expected:
- The file `/tmp/psi-test/keys/test-import.key` exists and starts with `-----BEGIN PRIVATE KEY-----`.

---

### 3. Import it

```bash
bun run start -- secrets import --yes --private-key /tmp/psi-test/keys/test-import.key
```

Expected:
- The command exits successfully.

---

### 4. Confirm the imported secret is listed

```bash
bun run start -- secrets list
```

Expected:
- Output contains `test-import` (the secret takes its name from the PEM filename).
