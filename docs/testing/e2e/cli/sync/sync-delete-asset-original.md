# CLI Manual Test: Sync After Deleting an Asset (Original Side)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that deleting an asset on the original removes it from the copy after
`sync`.

## Prep

Move into the CLI source directory, clean up any previous test run, create the original database from the v6 fixture and replicate it to a copy:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
```

Expected:
- Replication completes successfully.

## Test

### 1. Remove an asset from the original

The v6 fixture ships a known asset id `89171cd9-a652-4047-b869-1154bf2c95a1`.

```bash
bun run start -- remove --db /tmp/psi-test/original 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-test/original/asset/`, `display/`, and `thumb/`.
- The asset files are still present in `/tmp/psi-test/copy/asset/`.

---

### 2. Sync

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the asset is gone from the copy

```bash
ls /tmp/psi-test/copy/asset | grep 89171cd9-a652-4047-b869-1154bf2c95a1
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The `ls | grep` produces no output (the asset has been removed from the copy too).
- The two root hashes are identical.
