# CLI Manual Test: Import a PEM Key Pair

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets import --private-key <path>` stores a PEM private key as
an `encryption-key` secret.

`openssl` must be on `PATH`.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then generate a PEM private key:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-import-pem
mkdir -p /tmp/psi-cli-vault-plaintext-import-pem/config /tmp/psi-cli-vault-plaintext-import-pem/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-import-pem/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-import-pem/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
mkdir -p /tmp/psi-cli-vault-plaintext-import-pem/keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/psi-cli-vault-plaintext-import-pem/keys/test-import.key
head -1 /tmp/psi-cli-vault-plaintext-import-pem/keys/test-import.key
```

Expected:
- The key file starts with `-----BEGIN PRIVATE KEY-----`.

## Test

### 1. Import it

```bash
psi secrets import --yes --private-key /tmp/psi-cli-vault-plaintext-import-pem/keys/test-import.key
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the imported secret is listed

```bash
psi secrets list
```

Expected:
- Output contains `test-import` (the secret takes its name from the PEM filename) with type `encryption-key`.
