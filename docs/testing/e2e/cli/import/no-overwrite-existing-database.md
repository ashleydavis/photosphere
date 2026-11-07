# CLI Manual Test: Cannot Create Database Over Existing

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `init` refuses to overwrite an existing database directory.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-no-overwrite-existing-database
psi init --db /tmp/psi-cli-import-no-overwrite-existing-database/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-no-overwrite-existing-database/source`.

## Test

### 1. Attempt to create a second database in the same directory

```bash
psi init --db /tmp/psi-cli-import-no-overwrite-existing-database/source --yes
```

Expected:
- The command exits with a non-zero status.
- An error message indicates the database directory already contains a database.

## Check

### 2. Confirm the original database is intact

```bash
psi verify --db /tmp/psi-cli-import-no-overwrite-existing-database/source
```

Expected:
- Verification completes without errors.
- The database is still readable and intact.
