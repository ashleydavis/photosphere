# CLI Manual Test: Verify Detects a Deleted File

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `verify` reports a missing asset file as `Removed`.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, then delete its asset file from disk:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-verify-detect-deleted-file
psi init --db /tmp/psi-cli-verify-detect-deleted-file/source --yes
psi add test/test.jpg --db /tmp/psi-cli-verify-detect-deleted-file/source --yes
ls /tmp/psi-cli-verify-detect-deleted-file/source/asset
rm /tmp/psi-cli-verify-detect-deleted-file/source/asset/$(ls /tmp/psi-cli-verify-detect-deleted-file/source/asset)
```

Expected:
- Database created and the file is reported as added.
- `ls` lists one UUID. The asset file is then gone but the database metadata still references it.

## Test

### 1. Run verify

```bash
psi verify --db /tmp/psi-cli-verify-detect-deleted-file/source
```

Expected:
- The command reports that verification found issues.
- `Removed:` reports `1`.
- `Modified:` reports `0`.

## Check

The verify output in step 1 is the check.
