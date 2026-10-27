# CLI Manual Test: Decrypt a Database in Place

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `decrypt` turns an encrypted database back into a plain one that can be read without a key.

The key is generated into a plaintext vault under `/tmp/psi-cli-encryption-decrypt-in-place/vault`, so the test never touches the OS keychain.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, create an encrypted database with a generated key and add a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-encryption-decrypt-in-place
mkdir -p /tmp/psi-cli-encryption-decrypt-in-place/config /tmp/psi-cli-encryption-decrypt-in-place/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-encryption-decrypt-in-place/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-encryption-decrypt-in-place/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-encryption-decrypt-in-place/db --key dec-test-key --generate-key --yes
psi add test/test.png --db /tmp/psi-cli-encryption-decrypt-in-place/db --key dec-test-key --yes
ls /tmp/psi-cli-encryption-decrypt-in-place/db/.db
head -c 4 /tmp/psi-cli-encryption-decrypt-in-place/db/asset/$(ls /tmp/psi-cli-encryption-decrypt-in-place/db/asset); echo
```

Expected:
- The database is created and the file is added.
- `.db` holds `encryption.pub`, and the stored asset starts with `PSEN`.

## Test

### 1. Decrypt the database in place

```bash
psi decrypt --db /tmp/psi-cli-encryption-decrypt-in-place/db --key dec-test-key --yes
```

Expected:
- The command exits successfully and reports that the database was decrypted.

## Check

### 2. Confirm the stored bytes are plain

```bash
ls /tmp/psi-cli-encryption-decrypt-in-place/db/.db
head -c 4 /tmp/psi-cli-encryption-decrypt-in-place/db/asset/$(ls /tmp/psi-cli-encryption-decrypt-in-place/db/asset); echo
cmp /tmp/psi-cli-encryption-decrypt-in-place/db/asset/$(ls /tmp/psi-cli-encryption-decrypt-in-place/db/asset) test/test.png
```

Expected:
- `.db` no longer holds `encryption.pub`.
- The stored asset starts with the PNG signature, and `cmp` prints nothing: it is identical to the file that was added.

---

### 3. Read the database without a key

```bash
psi verify --db /tmp/psi-cli-encryption-decrypt-in-place/db --yes
psi list --db /tmp/psi-cli-encryption-decrypt-in-place/db --yes
```

Expected:
- Verification passes.
- `test.png` is listed.
