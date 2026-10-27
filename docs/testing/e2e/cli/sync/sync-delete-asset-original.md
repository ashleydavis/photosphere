# CLI Manual Test: Sync After Deleting an Asset (Original Side)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that deleting an asset on the original removes it from the copy after
`sync`.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create the original database from the v6 fixture and replicate it to a copy:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-sync-sync-delete-asset-original
mkdir -p /tmp/psi-cli-sync-sync-delete-asset-original
cp -r test/dbs/v6 /tmp/psi-cli-sync-sync-delete-asset-original/original
psi replicate --db /tmp/psi-cli-sync-sync-delete-asset-original/original --dest /tmp/psi-cli-sync-sync-delete-asset-original/copy --yes --force
```

Expected:
- Replication completes successfully.

## Test

### 1. Remove an asset from the original

The v6 fixture ships a known asset id `89171cd9-a652-4047-b869-1154bf2c95a1`.

```bash
psi remove --db /tmp/psi-cli-sync-sync-delete-asset-original/original 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-cli-sync-sync-delete-asset-original/original/asset/`, `display/`, and `thumb/`.
- The asset files are still present in `/tmp/psi-cli-sync-sync-delete-asset-original/copy/asset/`.

---

### 2. Sync

```bash
psi sync --db /tmp/psi-cli-sync-sync-delete-asset-original/original --dest /tmp/psi-cli-sync-sync-delete-asset-original/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the asset is gone from the copy

```bash
ls /tmp/psi-cli-sync-sync-delete-asset-original/copy/asset | grep 89171cd9-a652-4047-b869-1154bf2c95a1
psi root-hash --db /tmp/psi-cli-sync-sync-delete-asset-original/original
psi root-hash --db /tmp/psi-cli-sync-sync-delete-asset-original/copy
```

Expected:
- The `ls | grep` produces no output (the asset has been removed from the copy too).
- The two root hashes are identical.
