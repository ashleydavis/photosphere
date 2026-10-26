# CLI Manual Test: Consolidate With an Unrelated Remote

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `consolidate` joins a local database to a remote that holds a different database, so that the two can sync, without losing either side's files.

## Prep

Move into the CLI source directory, clean up any previous test run, and create two unrelated databases, each with its own file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/local --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/local --yes
bun run start -- init --db /tmp/psi-test/remote --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/remote --yes
```

Expected:
- Both databases are created and each has one file.

## Test

### 1. Confirm sync refuses the two before they are joined

```bash
bun run start -- sync --db /tmp/psi-test/local --dest /tmp/psi-test/remote --yes
```

Expected:
- The command exits with a non-zero status and says the databases are not related.

---

### 2. Consolidate the local database with the remote

```bash
bun run start -- consolidate --db /tmp/psi-test/local /tmp/psi-test/remote --yes
```

Expected:
- The command exits successfully.

---

### 3. Sync without naming a destination

```bash
bun run start -- sync --db /tmp/psi-test/local --yes
```

Expected:
- The sync runs against the remote and reports `Sync completed successfully`.

## Check

### 4. Confirm neither side lost a file and the two match

```bash
bun run start -- origin --db /tmp/psi-test/local
bun run start -- list --db /tmp/psi-test/local --yes
bun run start -- list --db /tmp/psi-test/remote --yes
bun run start -- compare --db /tmp/psi-test/local --dest /tmp/psi-test/remote --yes
bun run start -- verify --db /tmp/psi-test/local --yes
```

Expected:
- `origin` prints `/tmp/psi-test/remote`.
- Both sides list `test.jpg` and `test.png`.
- `compare` reports `No differences detected`, and the local database verifies.
