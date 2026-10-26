# CLI Manual Test: Database Summary

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `summary` reports the expected fields for a populated database.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database and add a file:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
```

Expected:
- Database created and the file is reported as added.

## Test

### 1. Show the database summary

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected output contains all of these fields:
- `Files imported:` (1 for the one added asset).
- `Total files:` (multiple, including display/thumb and metadata derivatives).
- `Total size:` in bytes or human-readable form.
- `Full root hash:` showing the aggregate root hash of the database.

## Check

The summary output in step 1 is the check.
