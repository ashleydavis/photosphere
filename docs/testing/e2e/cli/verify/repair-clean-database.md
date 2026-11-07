# CLI Manual Test: Repair a Clean Database (No Changes)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `repair` is a no-op when the target database has no issues.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, then replicate it:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-verify-repair-clean-database
psi init --db /tmp/psi-cli-verify-repair-clean-database/source --yes
psi add test/test.jpg --db /tmp/psi-cli-verify-repair-clean-database/source --yes
psi replicate --db /tmp/psi-cli-verify-repair-clean-database/source --dest /tmp/psi-cli-verify-repair-clean-database/replica --yes --force
```

Expected:
- The replica is reported as completed successfully.

## Test

### 1. Run repair against the clean source using the replica as the recovery source

```bash
psi repair --db /tmp/psi-cli-verify-repair-clean-database/source --source /tmp/psi-cli-verify-repair-clean-database/replica --yes
```

Expected:
- Output includes `Database repair completed - no issues found`.
- `Repaired:`, `Unrepaired:`, `Modified:`, and `Removed:` all report `0`.

## Check

### 2. Verify the source database is still intact

```bash
psi verify --db /tmp/psi-cli-verify-repair-clean-database/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.
