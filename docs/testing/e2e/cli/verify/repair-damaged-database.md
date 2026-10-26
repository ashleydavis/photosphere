# CLI Manual Test: Repair a Damaged Database From a Replica

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `repair` restores deleted and modified files using a replica as the
source of truth.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, replicate it, take a working copy, then damage the working copy by deleting its asset file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
cp -r /tmp/psi-test/source /tmp/psi-test/damaged
ls /tmp/psi-test/damaged/asset
rm /tmp/psi-test/damaged/asset/$(ls /tmp/psi-test/damaged/asset)
```

Expected:
- Database created, file added, replica completed, and the `damaged/` copy exists.
- `ls` lists one UUID, and that asset file is then deleted from the working copy.

If the database contains more than one asset, also corrupt another one with `echo "CORRUPTED" > /tmp/psi-test/damaged/asset/<other-asset-id>`. With the one asset this test adds, there is nothing else to corrupt.

## Test

### 1. Confirm verify detects the damage

```bash
bun run start -- verify --db /tmp/psi-test/damaged --full
```

Expected:
- The command reports that verification found issues.

---

### 2. Repair the damaged database from the replica

```bash
bun run start -- repair --db /tmp/psi-test/damaged --source /tmp/psi-test/replica --yes --full
```

Expected:
- Output includes `Database repair completed successfully`.
- `Repaired:` reports a value greater than `0`.

## Check

### 3. Verify the repaired database

```bash
bun run start -- verify --db /tmp/psi-test/damaged
```

Expected:
- Output includes `Database verification passed - all files are intact`.
- `Modified:` and `Removed:` both report `0`.
