# CLI Manual Test: Decrypt a Database in Place

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `decrypt` turns an encrypted database back into a plain one that can be read without a key.

The key is generated into a plaintext vault under `/tmp/psi-test/vault`, so the test never touches the OS keychain.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, create an encrypted database with a generated key and add a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/db --key dec-test-key --generate-key --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --key dec-test-key --yes
ls /tmp/psi-test/db/.db
head -c 4 /tmp/psi-test/db/asset/$(ls /tmp/psi-test/db/asset); echo
```

Expected:
- The database is created and the file is added.
- `.db` holds `encryption.pub`, and the stored asset starts with `PSEN`.

## Test

### 1. Decrypt the database in place

```bash
bun run start -- decrypt --db /tmp/psi-test/db --key dec-test-key --yes
```

Expected:
- The command exits successfully and reports that the database was decrypted.

## Check

### 2. Confirm the stored bytes are plain

```bash
ls /tmp/psi-test/db/.db
head -c 4 /tmp/psi-test/db/asset/$(ls /tmp/psi-test/db/asset); echo
cmp /tmp/psi-test/db/asset/$(ls /tmp/psi-test/db/asset) ../../test/test.png
```

Expected:
- `.db` no longer holds `encryption.pub`.
- The stored asset starts with the PNG signature, and `cmp` prints nothing: it is identical to the file that was added.

---

### 3. Read the database without a key

```bash
bun run start -- verify --db /tmp/psi-test/db --yes
bun run start -- list --db /tmp/psi-test/db --yes
```

Expected:
- Verification passes.
- `test.png` is listed.
