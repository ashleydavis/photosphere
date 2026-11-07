# CLI Manual Test: Replicate a Database With a Deleted Asset

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that replicating a database which has had an asset removed produces a
replica that also lacks the deleted asset.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, take a working copy of the v6 fixture and remove its known asset `89171cd9-a652-4047-b869-1154bf2c95a1`:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-replication-replicate-deleted-asset
mkdir -p /tmp/psi-cli-replication-replicate-deleted-asset
cp -r test/dbs/v6 /tmp/psi-cli-replication-replicate-deleted-asset/source
psi remove --db /tmp/psi-cli-replication-replicate-deleted-asset/source 89171cd9-a652-4047-b869-1154bf2c95a1 --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.
- The asset files are gone from `/tmp/psi-cli-replication-replicate-deleted-asset/source/asset/`, `display/`, and `thumb/`.

## Test

### 1. Replicate the source to a fresh destination

```bash
psi replicate --db /tmp/psi-cli-replication-replicate-deleted-asset/source --dest /tmp/psi-cli-replication-replicate-deleted-asset/replica --yes --force
```

Expected:
- Replication completes successfully.

## Check

### 2. Confirm the deleted asset is also absent from the replica

```bash
find /tmp/psi-cli-replication-replicate-deleted-asset/replica -name '89171cd9-a652-4047-b869-1154bf2c95a1*'
```

Expected:
- The command produces no output. The v6 fixture holds only this one asset, so the replica has no `asset/`, `display/` or `thumb/` file for it, and those folders may not exist at all.

---

### 3. Confirm the replica matches the source

```bash
psi root-hash --db /tmp/psi-cli-replication-replicate-deleted-asset/source
psi root-hash --db /tmp/psi-cli-replication-replicate-deleted-asset/replica
psi compare --db /tmp/psi-cli-replication-replicate-deleted-asset/source --dest /tmp/psi-cli-replication-replicate-deleted-asset/replica --yes
```

Expected:
- The two root hashes are identical.
- `compare` reports `No differences detected`.
