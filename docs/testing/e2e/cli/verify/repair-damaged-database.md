# CLI Manual Test: Repair a Damaged Database From a Replica

Test that `repair` restores deleted and modified files using a replica as the
source of truth.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
```

---

### 2. Create a database, add a file, replicate it, then take a working copy

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
cp -r /tmp/psi-test/source /tmp/psi-test/damaged
```

Expected:
- Database created, file added, replica completed, and the `damaged/` copy exists.

---

### 3. Damage the working copy

Delete one asset file and corrupt another (note: in a database with only one
asset the same file is both deleted and corrupted in alternate runs; below we
delete one and tamper with the merkle data file).

```bash
ls /tmp/psi-test/damaged/asset
```

Note an asset UUID, then:

```bash
rm /tmp/psi-test/damaged/asset/<asset-id>
```

If the database contains more than one asset, also corrupt one with:

```bash
echo "CORRUPTED" > /tmp/psi-test/damaged/asset/<other-asset-id>
```

---

### 4. Verify the damage

```bash
bun run start -- verify --db /tmp/psi-test/damaged --full
```

Expected:
- The command reports that verification found issues.

---

### 5. Repair the damaged database from the replica

```bash
bun run start -- repair --db /tmp/psi-test/damaged --source /tmp/psi-test/replica --yes --full
```

Expected:
- Output includes `Database repair completed successfully`.
- `Repaired:` reports a value greater than `0`.

---

### 6. Verify the repaired database

```bash
bun run start -- verify --db /tmp/psi-test/damaged
```

Expected:
- Output includes `Database verification passed - all files are intact`.
- `Modified:` and `Removed:` both report `0`.
