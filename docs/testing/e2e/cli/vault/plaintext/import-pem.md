# CLI Manual Test: Import a PEM Key Pair

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets import --private-key <path>` stores a PEM private key as
an `encryption-key` secret.

`openssl` must be on `PATH`.

## Prep

Move into the CLI source directory and point the CLI at empty config and vault directories, then generate a PEM private key:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
mkdir -p /tmp/psi-test/keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/psi-test/keys/test-import.key
head -1 /tmp/psi-test/keys/test-import.key
```

Expected:
- The key file starts with `-----BEGIN PRIVATE KEY-----`.

## Test

### 1. Import it

```bash
bun run start -- secrets import --yes --private-key /tmp/psi-test/keys/test-import.key
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the imported secret is listed

```bash
bun run start -- secrets list
```

Expected:
- Output contains `test-import` (the secret takes its name from the PEM filename) with type `encryption-key`.
