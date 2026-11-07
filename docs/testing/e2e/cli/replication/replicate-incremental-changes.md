# CLI Manual Test: Replicate Incremental Changes

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that re-replicating after adding files to the source copies just the new
files.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, replicate it, then add a new file to the source:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-replication-replicate-incremental-changes
psi init --db /tmp/psi-cli-replication-replicate-incremental-changes/source --yes
psi add test/test.jpg --db /tmp/psi-cli-replication-replicate-incremental-changes/source --yes
psi replicate --db /tmp/psi-cli-replication-replicate-incremental-changes/source --dest /tmp/psi-cli-replication-replicate-incremental-changes/replica --yes --force
psi add test/test.png --db /tmp/psi-cli-replication-replicate-incremental-changes/source --yes
```

Expected:
- Replication completes successfully.
- The second `add` shows `Files added: 1`.

## Test

### 1. Re-replicate

```bash
psi replicate --db /tmp/psi-cli-replication-replicate-incremental-changes/source --dest /tmp/psi-cli-replication-replicate-incremental-changes/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports a small non-zero value (typically `3`: original, display, and thumb for the one new asset).

## Check

### 2. Confirm the databases are equivalent again

```bash
psi compare --db /tmp/psi-cli-replication-replicate-incremental-changes/source --dest /tmp/psi-cli-replication-replicate-incremental-changes/replica --yes
psi root-hash --db /tmp/psi-cli-replication-replicate-incremental-changes/source
psi root-hash --db /tmp/psi-cli-replication-replicate-incremental-changes/replica
```

Expected:
- `compare` reports `No differences detected`.
- The root hashes for source and replica match.
