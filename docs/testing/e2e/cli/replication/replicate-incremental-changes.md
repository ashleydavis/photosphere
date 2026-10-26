# CLI Manual Test: Replicate Incremental Changes

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that re-replicating after adding files to the source copies just the new
files.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, replicate it, then add a new file to the source:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Replication completes successfully.
- The second `add` shows `Files added: 1`.

## Test

### 1. Re-replicate

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports a small non-zero value (typically `3`: original, display, and thumb for the one new asset).

## Check

### 2. Confirm the databases are equivalent again

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
bun run start -- root-hash --db /tmp/psi-test/source
bun run start -- root-hash --db /tmp/psi-test/replica
```

Expected:
- `compare` reports `No differences detected`.
- The root hashes for source and replica match.
