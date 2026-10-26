# CLI Manual Test: Replicate an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that an encrypted database replicates to a copy that stays encrypted with the same key and matches the source.

The key is generated into a plaintext vault under `/tmp/psi-test/vault`, so the test never touches the OS keychain.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, create an encrypted database and add a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/source --key rep-enc-key --generate-key --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --key rep-enc-key --yes
```

Expected:
- The database is created and the file is added.

## Test

### 1. Replicate the encrypted database

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --key rep-enc-key --dk rep-enc-key --yes
```

Expected:
- `✅ Replication completed successfully`, with files copied.

## Check

### 2. Confirm the replica is encrypted

```bash
ls /tmp/psi-test/replica/.db
head -c 4 /tmp/psi-test/replica/asset/$(ls /tmp/psi-test/replica/asset); echo
```

Expected:
- The replica's `.db` holds `encryption.pub`, and its stored asset starts with `PSEN`.

---

### 3. Read the replica with the key and compare it with the source

```bash
bun run start -- verify --db /tmp/psi-test/replica --key rep-enc-key --yes
bun run start -- list --db /tmp/psi-test/replica --key rep-enc-key --yes
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --key rep-enc-key --dk rep-enc-key --yes
```

Expected:
- Verification passes and `test.jpg` is listed.
- `compare` reports `No differences detected`.
