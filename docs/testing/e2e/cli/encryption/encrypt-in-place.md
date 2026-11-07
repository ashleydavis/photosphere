# CLI Manual Test: Encrypt a Database in Place

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `encrypt` turns a plain database into an encrypted one that can only be read with its key.

The key is generated into a plaintext vault under `/tmp/psi-cli-encryption-encrypt-in-place/vault`, so the test never touches the OS keychain.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, create a plain database and add a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-encryption-encrypt-in-place
mkdir -p /tmp/psi-cli-encryption-encrypt-in-place/config /tmp/psi-cli-encryption-encrypt-in-place/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-encryption-encrypt-in-place/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-encryption-encrypt-in-place/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-encryption-encrypt-in-place/db --yes
psi add test/test.png --db /tmp/psi-cli-encryption-encrypt-in-place/db --yes
head -c 4 /tmp/psi-cli-encryption-encrypt-in-place/db/asset/$(ls /tmp/psi-cli-encryption-encrypt-in-place/db/asset); echo
```

Expected:
- The database is created and the file is added.
- The first 4 bytes of the stored asset are the PNG signature (`\x89PNG`), so it is stored as plain bytes.

## Test

### 1. Encrypt the database in place with a generated key

```bash
psi encrypt --db /tmp/psi-cli-encryption-encrypt-in-place/db --key enc-test-key --generate-key --yes
```

Expected:
- The command exits successfully and reports that the database was encrypted.

## Check

### 2. Confirm the stored bytes are encrypted

```bash
ls /tmp/psi-cli-encryption-encrypt-in-place/db/.db
head -c 4 /tmp/psi-cli-encryption-encrypt-in-place/db/asset/$(ls /tmp/psi-cli-encryption-encrypt-in-place/db/asset); echo
```

Expected:
- `.db` now holds `encryption.pub`.
- The first 4 bytes of the stored asset are `PSEN`, the encrypted file header, not the PNG signature.

---

### 3. Read the database with the key

```bash
psi verify --db /tmp/psi-cli-encryption-encrypt-in-place/db --key enc-test-key --yes
psi list --db /tmp/psi-cli-encryption-encrypt-in-place/db --key enc-test-key --yes
```

Expected:
- Verification passes.
- `test.png` is listed.

---

### 4. Try to read the database without the key

```bash
psi list --db /tmp/psi-cli-encryption-encrypt-in-place/db --yes
```

Expected:
- The command exits with a non-zero status and says the database is encrypted and needs a key.
