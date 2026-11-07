# CLI Manual Test: Replicate an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that an encrypted database replicates to a copy that stays encrypted with the same key and matches the source.

The key is generated into a plaintext vault under `/tmp/psi-cli-encryption-replicate-encrypted/vault`, so the test never touches the OS keychain.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, create an encrypted database and add a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-encryption-replicate-encrypted
mkdir -p /tmp/psi-cli-encryption-replicate-encrypted/config /tmp/psi-cli-encryption-replicate-encrypted/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-encryption-replicate-encrypted/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-encryption-replicate-encrypted/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-encryption-replicate-encrypted/source --key rep-enc-key --generate-key --yes
psi add test/test.jpg --db /tmp/psi-cli-encryption-replicate-encrypted/source --key rep-enc-key --yes
```

Expected:
- The database is created and the file is added.

## Test

### 1. Replicate the encrypted database

```bash
psi replicate --db /tmp/psi-cli-encryption-replicate-encrypted/source --dest /tmp/psi-cli-encryption-replicate-encrypted/replica --key rep-enc-key --dk rep-enc-key --yes
```

Expected:
- `✅ Replication completed successfully`, with files copied.

## Check

### 2. Confirm the replica is encrypted

```bash
ls /tmp/psi-cli-encryption-replicate-encrypted/replica/.db
head -c 4 /tmp/psi-cli-encryption-replicate-encrypted/replica/asset/$(ls /tmp/psi-cli-encryption-replicate-encrypted/replica/asset); echo
```

Expected:
- The replica's `.db` holds `encryption.pub`, and its stored asset starts with `PSEN`.

---

### 3. Read the replica with the key and compare it with the source

```bash
psi verify --db /tmp/psi-cli-encryption-replicate-encrypted/replica --key rep-enc-key --yes
psi list --db /tmp/psi-cli-encryption-replicate-encrypted/replica --key rep-enc-key --yes
psi compare --db /tmp/psi-cli-encryption-replicate-encrypted/source --dest /tmp/psi-cli-encryption-replicate-encrypted/replica --key rep-enc-key --dk rep-enc-key --yes
```

Expected:
- Verification passes and `test.jpg` is listed.
- `compare` reports `No differences detected`.
