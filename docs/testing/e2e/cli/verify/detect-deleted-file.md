# CLI Manual Test: Verify Detects a Deleted File

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `verify` reports a missing asset file as `Removed`.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, then delete its asset file from disk:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
ls /tmp/psi-test/source/asset
rm /tmp/psi-test/source/asset/$(ls /tmp/psi-test/source/asset)
```

Expected:
- Database created and the file is reported as added.
- `ls` lists one UUID. The asset file is then gone but the database metadata still references it.

## Test

### 1. Run verify

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- The command reports that verification found issues.
- `Removed:` reports `1`.
- `Modified:` reports `0`.

## Check

The verify output in step 1 is the check.
