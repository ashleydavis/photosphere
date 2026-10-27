# CLI Manual Test: Sync Original to Copy

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `sync` propagates new files added on the original side over to the
copy.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then add a new file to the original:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-sync-sync-original-to-copy
mkdir -p /tmp/psi-cli-sync-sync-original-to-copy
cp -r test/dbs/v6 /tmp/psi-cli-sync-sync-original-to-copy/original
psi replicate --db /tmp/psi-cli-sync-sync-original-to-copy/original --dest /tmp/psi-cli-sync-sync-original-to-copy/copy --yes --force
psi add test/test.png --db /tmp/psi-cli-sync-sync-original-to-copy/original --yes
```

Expected:
- Replication completes successfully.
- The `add` shows `Files added: 1`.

## Test

### 1. Confirm the root hashes now differ

```bash
psi root-hash --db /tmp/psi-cli-sync-sync-original-to-copy/original
psi root-hash --db /tmp/psi-cli-sync-sync-original-to-copy/copy
```

Expected:
- The two values are different.

---

### 2. Sync original to copy

```bash
psi sync --db /tmp/psi-cli-sync-sync-original-to-copy/original --dest /tmp/psi-cli-sync-sync-original-to-copy/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the root hashes match again

```bash
psi root-hash --db /tmp/psi-cli-sync-sync-original-to-copy/original
psi root-hash --db /tmp/psi-cli-sync-sync-original-to-copy/copy
```

Expected:
- The two values are identical.
