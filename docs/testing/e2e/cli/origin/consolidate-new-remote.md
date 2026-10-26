# CLI Manual Test: Consolidate Into a New Remote

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `consolidate` creates the remote when nothing is there, records it as the origin, and leaves the two able to sync.

## Prep

Move into the CLI source directory, clean up any previous test run and create a local database with a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/local --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/local --yes
```

Expected:
- The database is created and the file is added.

## Test

### 1. Consolidate into a remote that does not exist

```bash
bun run start -- consolidate --db /tmp/psi-test/local /tmp/psi-test/remote --yes
```

Expected:
- The command exits successfully and reports that the remote was created.

---

### 2. Add a file locally and sync without naming a destination

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/local --yes
bun run start -- sync --db /tmp/psi-test/local --yes
```

Expected:
- The sync runs against the remote and reports `Sync completed successfully`.

## Check

### 3. Confirm the origin and that the remote matches

```bash
bun run start -- origin --db /tmp/psi-test/local
bun run start -- list --db /tmp/psi-test/remote --yes
bun run start -- compare --db /tmp/psi-test/local --dest /tmp/psi-test/remote --yes
bun run start -- verify --db /tmp/psi-test/remote --yes
```

Expected:
- `origin` prints `/tmp/psi-test/remote`.
- The remote lists `test.jpg` and `test.png`.
- `compare` reports `No differences detected`, and the remote verifies.
