# CLI Manual Test: Cannot Create Database Over Existing

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `init` refuses to overwrite an existing database directory.

## Prep

Move into the CLI source directory, clean up any previous test run and create a new database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

## Test

### 1. Attempt to create a second database in the same directory

```bash
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected:
- The command exits with a non-zero status.
- An error message indicates the database directory already contains a database.

## Check

### 2. Confirm the original database is intact

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- The database is still readable and intact.
