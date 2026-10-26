# CLI Manual Test: Compare After Changes

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `compare` detects differences when one database is ahead of the other.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, replicate it, then add a second file to the source only:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Replication completes successfully, so source and replica are identical at that point.
- The second `add` shows `Files added: 1`.

## Test

### 1. Compare source and replica

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- Output reports a non-zero number of differences (typically `Databases have 3 differences` because adding one asset adds the original, display, and thumb entries to the merkle tree).

## Check

The compare output in step 1 is the check.
