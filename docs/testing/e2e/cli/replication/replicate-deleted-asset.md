# CLI Manual Test: Replicate a Database With a Deleted Asset

Test that replicating a database which has had an asset removed produces a
replica that also lacks the deleted asset.

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

### 2. Take a working copy of the v6 fixture and remove an asset

The v6 fixture ships a known asset id `89171cd9-a652-4047-b869-1154bf2c95a1`.

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/source
bun run start -- remove --db /tmp/psi-test/source 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-test/source/asset/`, `display/`, and `thumb/`.

---

### 3. Replicate the source to a fresh destination

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replication completes successfully.

---

### 4. Confirm the deleted asset is also absent from the replica

```bash
ls /tmp/psi-test/replica/asset | grep 89171cd9-a652-4047-b869-1154bf2c95a1
```

Expected:
- The command produces no output.

---

### 5. Confirm the replica's root hash matches the source's

```bash
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- root-hash --db /tmp/psi-test/replica
```

Expected:
- The two values are identical.
- `bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes` reports `No differences detected`.
