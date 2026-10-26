# CLI Manual Test: Replication Between Unrelated Databases Fails

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `replicate` refuses to overwrite a destination that belongs to a
different database.

## Prep

Move into the CLI source directory, clean up any previous test run and create two independent databases:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/first --yes
bun run start -- init --db /tmp/psi-test/second --yes
```

Expected:
- Both databases are created.

## Test

### 1. Confirm the two databases have different IDs

```bash
bun run start -- database-id --db /tmp/psi-test/first --yes
bun run start -- database-id --db /tmp/psi-test/second --yes
```

Expected:
- The two UUIDs are different.

---

### 2. Attempt to replicate the first over the second

```bash
bun run start -- replicate --db /tmp/psi-test/first --dest /tmp/psi-test/second --yes
```

Expected:
- The command exits with a non-zero status.
- The error message contains `different ID than the source database` and `not related to the source database`.
- It prints both the source and destination database IDs.

## Check

The replicate output in step 2 is the check.
