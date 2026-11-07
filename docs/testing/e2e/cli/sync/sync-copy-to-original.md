# CLI Manual Test: Sync Copy to Original

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `sync` is bidirectional: a file added on the copy side flows back to
the original through the same `sync` command.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then add a new file to the **copy**:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-sync-sync-copy-to-original
mkdir -p /tmp/psi-cli-sync-sync-copy-to-original
cp -r test/dbs/v6 /tmp/psi-cli-sync-sync-copy-to-original/original
psi replicate --db /tmp/psi-cli-sync-sync-copy-to-original/original --dest /tmp/psi-cli-sync-sync-copy-to-original/copy --yes --force
psi add test/test.png --db /tmp/psi-cli-sync-sync-copy-to-original/copy --yes
```

Expected:
- Replication completes successfully.
- The `add` shows `Files added: 1`.

## Test

### 1. Sync the two databases

```bash
psi sync --db /tmp/psi-cli-sync-sync-copy-to-original/original --dest /tmp/psi-cli-sync-sync-copy-to-original/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 2. Confirm the root hashes match

```bash
psi root-hash --db /tmp/psi-cli-sync-sync-copy-to-original/original
psi root-hash --db /tmp/psi-cli-sync-sync-copy-to-original/copy
```

Expected:
- The two values are identical (the new file added to the copy is now present in the original).
