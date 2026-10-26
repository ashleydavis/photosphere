# CLI Manual Test: Encrypt a Database in Place

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `encrypt` turns a plain database into an encrypted one that can only be read with its key.

The key is generated into a plaintext vault under `/tmp/psi-test/vault`, so the test never touches the OS keychain.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, create a plain database and add a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/db --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --yes
head -c 4 /tmp/psi-test/db/asset/$(ls /tmp/psi-test/db/asset); echo
```

Expected:
- The database is created and the file is added.
- The first 4 bytes of the stored asset are the PNG signature (`\x89PNG`), so it is stored as plain bytes.

## Test

### 1. Encrypt the database in place with a generated key

```bash
bun run start -- encrypt --db /tmp/psi-test/db --key enc-test-key --generate-key --yes
```

Expected:
- The command exits successfully and reports that the database was encrypted.

## Check

### 2. Confirm the stored bytes are encrypted

```bash
ls /tmp/psi-test/db/.db
head -c 4 /tmp/psi-test/db/asset/$(ls /tmp/psi-test/db/asset); echo
```

Expected:
- `.db` now holds `encryption.pub`.
- The first 4 bytes of the stored asset are `PSEN`, the encrypted file header, not the PNG signature.

---

### 3. Read the database with the key

```bash
bun run start -- verify --db /tmp/psi-test/db --key enc-test-key --yes
bun run start -- list --db /tmp/psi-test/db --key enc-test-key --yes
```

Expected:
- Verification passes.
- `test.png` is listed.

---

### 4. Try to read the database without the key

```bash
bun run start -- list --db /tmp/psi-test/db --yes
```

Expected:
- The command exits with a non-zero status and says the database is encrypted and needs a key.
