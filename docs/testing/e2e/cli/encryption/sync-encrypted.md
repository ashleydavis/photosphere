# CLI Manual Test: Sync Two Copies of an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a file added to one copy of an encrypted database reaches the other through `sync`, and stays encrypted.

The key is generated into a plaintext vault under `/tmp/psi-cli-encryption-sync-encrypted/vault`, so the test never touches the OS keychain.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, create an encrypted database with a file, replicate it, then add a second file to the copy:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-encryption-sync-encrypted
mkdir -p /tmp/psi-cli-encryption-sync-encrypted/config /tmp/psi-cli-encryption-sync-encrypted/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-encryption-sync-encrypted/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-encryption-sync-encrypted/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-encryption-sync-encrypted/original --key sync-enc-key --generate-key --yes
psi add test/test.jpg --db /tmp/psi-cli-encryption-sync-encrypted/original --key sync-enc-key --yes
psi replicate --db /tmp/psi-cli-encryption-sync-encrypted/original --dest /tmp/psi-cli-encryption-sync-encrypted/copy --key sync-enc-key --dk sync-enc-key --yes
psi add test/test.png --db /tmp/psi-cli-encryption-sync-encrypted/copy --key sync-enc-key --yes
```

Expected:
- Both files are added and the replication completes successfully.

## Test

### 1. Sync the two copies

```bash
psi sync --db /tmp/psi-cli-encryption-sync-encrypted/original --dest /tmp/psi-cli-encryption-sync-encrypted/copy --key sync-enc-key --dk sync-enc-key --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 2. Confirm both copies hold both files and match

```bash
psi list --db /tmp/psi-cli-encryption-sync-encrypted/original --key sync-enc-key --yes
psi root-hash --db /tmp/psi-cli-encryption-sync-encrypted/original --key sync-enc-key
psi root-hash --db /tmp/psi-cli-encryption-sync-encrypted/copy --key sync-enc-key
```

Expected:
- The original lists `test.jpg` and `test.png`.
- The two root hashes are identical.

---

### 3. Confirm the synced file is stored encrypted in the original

```bash
for f in /tmp/psi-cli-encryption-sync-encrypted/original/asset/*; do head -c 4 "$f"; echo; done
```

Expected:
- Every stored asset starts with `PSEN`.
