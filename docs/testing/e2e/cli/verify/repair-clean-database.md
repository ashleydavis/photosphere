# CLI Manual Test: Repair a Clean Database (No Changes)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `repair` is a no-op when the target database has no issues.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, then replicate it:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- The replica is reported as completed successfully.

## Test

### 1. Run repair against the clean source using the replica as the recovery source

```bash
bun run start -- repair --db /tmp/psi-test/source --source /tmp/psi-test/replica --yes
```

Expected:
- Output includes `Database repair completed - no issues found`.
- `Repaired:`, `Unrepaired:`, `Modified:`, and `Removed:` all report `0`.

## Check

### 2. Verify the source database is still intact

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.
