# CLI Manual Test: Full Verify

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `verify --full` performs a deeper integrity scan than the default
quick scan.

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

### 1. Run a quick verify

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.

---

### 2. Run a full verify

```bash
bun run start -- verify --db /tmp/psi-test/source --full
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.
- The output indicates that file hashes were checked (the full verify recomputes each file's hash; the quick verify only checks sizes and merkle metadata).

## Check

The verify output in steps 1 and 2 is the check.
