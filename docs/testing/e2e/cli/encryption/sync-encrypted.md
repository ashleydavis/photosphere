# CLI Manual Test: Sync Two Copies of an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a file added to one copy of an encrypted database reaches the other through `sync`, and stays encrypted.

The key is generated into a plaintext vault under `/tmp/psi-test/vault`, so the test never touches the OS keychain.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, create an encrypted database with a file, replicate it, then add a second file to the copy:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/original --key sync-enc-key --generate-key --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/original --key sync-enc-key --yes
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --key sync-enc-key --dk sync-enc-key --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/copy --key sync-enc-key --yes
```

Expected:
- Both files are added and the replication completes successfully.

## Test

### 1. Sync the two copies

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --key sync-enc-key --dk sync-enc-key --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 2. Confirm both copies hold both files and match

```bash
bun run start -- list --db /tmp/psi-test/original --key sync-enc-key --yes
bun run start -- root-hash --db /tmp/psi-test/original --key sync-enc-key
bun run start -- root-hash --db /tmp/psi-test/copy --key sync-enc-key
```

Expected:
- The original lists `test.jpg` and `test.png`.
- The two root hashes are identical.

---

### 3. Confirm the synced file is stored encrypted in the original

```bash
for f in /tmp/psi-test/original/asset/*; do head -c 4 "$f"; echo; done
```

Expected:
- Every stored asset starts with `PSEN`.
