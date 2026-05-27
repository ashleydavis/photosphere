# CLI Manual Test: Sync After Deleting an Asset (Original Side)

Test that deleting an asset on the original removes it from the copy after
`sync`.

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

### 2. Create the original database from the v6 fixture and replicate to a copy

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
```

Expected:
- Replication completes successfully.

---

### 3. Remove an asset from the original

The v6 fixture ships a known asset id `89171cd9-a652-4047-b869-1154bf2c95a1`.

```bash
bun run start -- remove --db /tmp/psi-test/original 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-test/original/asset/`, `display/`, and `thumb/`.
- The asset files are still present in `/tmp/psi-test/copy/asset/`.

---

### 4. Sync

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

---

### 5. Confirm the asset is gone from the copy

```bash
ls /tmp/psi-test/copy/asset | grep 89171cd9-a652-4047-b869-1154bf2c95a1
```

Expected:
- The command produces no output (the asset has been removed from the copy too).
- `bun run start -- root-hash --db /tmp/psi-test/original` and `... --db /tmp/psi-test/copy` produce the same value.
