# CLI Manual Test: Upgrade v3 Database to v6

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `upgrade` brings a v3 database to the current schema version (6).

## Prep

Move into the CLI source directory, clean up any previous test run and copy the v3 fixture to a working directory:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v3 /tmp/psi-test/upgrade
```

Expected:
- The fixture is copied to `/tmp/psi-test/upgrade`.

## Test

### 1. Run upgrade

```bash
bun run start -- upgrade --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output includes `Database upgraded successfully to version 6`.

## Check

### 2. Confirm the database is now version 6

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output contains `Database version: 6`.

---

### 3. Verify the upgraded database

```bash
bun run start -- verify --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output contains `Database verification passed`.
