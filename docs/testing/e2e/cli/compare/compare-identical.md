# CLI Manual Test: Compare Two Identical Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `compare` reports no differences for two identical databases.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file and replicate it:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replica is reported as completed successfully.

## Test

### 1. Compare source and replica

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- Output includes `No differences detected`.

---

### 2. Compare a database with itself

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/source --yes
```

Expected:
- Output includes `No differences detected`.

## Check

The compare output in steps 1 and 2 is the check.
