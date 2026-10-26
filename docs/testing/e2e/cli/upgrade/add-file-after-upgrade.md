# CLI Manual Test: Add a File to a Freshly-Upgraded v6 Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database upgraded from an older format accepts new file imports.

## Prep

Move into the CLI source directory, clean up any previous test run, copy the v6 fixture to a working directory and record its starting file count:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v6 /tmp/psi-test/upgrade
bun run start -- summary --db /tmp/psi-test/upgrade --yes | grep "Total files:"
```

(For deeper coverage, repeat the test against the v2-v5 fixtures by also running
`bun run start -- upgrade --db /tmp/psi-test/upgrade --yes` after the copy.)

Expected:
- A non-zero `Total files:` value. Record it as the baseline.

## Test

### 1. Add a new file

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output reports the file as added.

## Check

### 2. Confirm the file count increased

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes | grep "Total files:"
```

Expected:
- The new value is the baseline plus 3 (original + display + thumb merkle entries for the one new asset).

---

### 3. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output includes `Database verification passed`.
