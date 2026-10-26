# CLI Manual Test: Sync Original to Copy

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `sync` propagates new files added on the original side over to the
copy.

## Prep

Move into the CLI source directory, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then add a new file to the original:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
bun run start -- add ../../test/test.png --db /tmp/psi-test/original --yes
```

Expected:
- Replication completes successfully.
- The `add` shows `Files added: 1`.

## Test

### 1. Confirm the root hashes now differ

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are different.

---

### 2. Sync original to copy

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the root hashes match again

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are identical.
