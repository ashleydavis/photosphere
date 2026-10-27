# CLI Manual Test: Repair a Damaged Database From a Replica

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `repair` restores deleted and modified files using a replica as the
source of truth.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, replicate it, take a working copy, then damage the working copy by deleting its asset file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-verify-repair-damaged-database
psi init --db /tmp/psi-cli-verify-repair-damaged-database/source --yes
psi add test/test.jpg --db /tmp/psi-cli-verify-repair-damaged-database/source --yes
psi replicate --db /tmp/psi-cli-verify-repair-damaged-database/source --dest /tmp/psi-cli-verify-repair-damaged-database/replica --yes --force
cp -r /tmp/psi-cli-verify-repair-damaged-database/source /tmp/psi-cli-verify-repair-damaged-database/damaged
ls /tmp/psi-cli-verify-repair-damaged-database/damaged/asset
rm /tmp/psi-cli-verify-repair-damaged-database/damaged/asset/$(ls /tmp/psi-cli-verify-repair-damaged-database/damaged/asset)
```

Expected:
- Database created, file added, replica completed, and the `damaged/` copy exists.
- `ls` lists one UUID, and that asset file is then deleted from the working copy.

If the database contains more than one asset, also corrupt another one with `echo "CORRUPTED" > /tmp/psi-cli-verify-repair-damaged-database/damaged/asset/<other-asset-id>`. With the one asset this test adds, there is nothing else to corrupt.

## Test

### 1. Confirm verify detects the damage

```bash
psi verify --db /tmp/psi-cli-verify-repair-damaged-database/damaged --full
```

Expected:
- The command reports that verification found issues.

---

### 2. Repair the damaged database from the replica

```bash
psi repair --db /tmp/psi-cli-verify-repair-damaged-database/damaged --source /tmp/psi-cli-verify-repair-damaged-database/replica --yes --full
```

Expected:
- Output includes `Database repair completed successfully`.
- `Repaired:` reports a value greater than `0`.

## Check

### 3. Verify the repaired database

```bash
psi verify --db /tmp/psi-cli-verify-repair-damaged-database/damaged
```

Expected:
- Output includes `Database verification passed - all files are intact`.
- `Modified:` and `Removed:` both report `0`.
