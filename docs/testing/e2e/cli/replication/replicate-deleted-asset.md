# CLI Manual Test: Replicate a Database With a Deleted Asset

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that replicating a database which has had an asset removed produces a
replica that also lacks the deleted asset.

## Prep

Move into the CLI source directory, clean up any previous test run, take a working copy of the v6 fixture and remove its known asset `89171cd9-a652-4047-b869-1154bf2c95a1`:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v6 /tmp/psi-test/source
bun run start -- remove --db /tmp/psi-test/source 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-test/source/asset/`, `display/`, and `thumb/`.

## Test

### 1. Replicate the source to a fresh destination

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replication completes successfully.

## Check

### 2. Confirm the deleted asset is also absent from the replica

```bash
ls /tmp/psi-test/replica/asset | grep 89171cd9-a652-4047-b869-1154bf2c95a1
```

Expected:
- The command produces no output.

---

### 3. Confirm the replica matches the source

```bash
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- root-hash --db /tmp/psi-test/replica
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- The two root hashes are identical.
- `compare` reports `No differences detected`.
