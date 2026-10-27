# CLI Manual Test: Compare After Changes

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `compare` detects differences when one database is ahead of the other.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, replicate it, then add a second file to the source only:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-compare-compare-after-changes
psi init --db /tmp/psi-cli-compare-compare-after-changes/source --yes
psi add test/test.jpg --db /tmp/psi-cli-compare-compare-after-changes/source --yes
psi replicate --db /tmp/psi-cli-compare-compare-after-changes/source --dest /tmp/psi-cli-compare-compare-after-changes/replica --yes --force
psi add test/test.png --db /tmp/psi-cli-compare-compare-after-changes/source --yes
```

Expected:
- Replication completes successfully, so source and replica are identical at that point.
- The second `add` shows `Files added: 1`.

## Test

### 1. Compare source and replica

```bash
psi compare --db /tmp/psi-cli-compare-compare-after-changes/source --dest /tmp/psi-cli-compare-compare-after-changes/replica --yes
```

Expected:
- Output reports a non-zero number of differences (typically `Databases have 3 differences` because adding one asset adds the original, display, and thumb entries to the merkle tree).

## Check

The compare output in step 1 is the check.
