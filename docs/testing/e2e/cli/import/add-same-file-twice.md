# CLI Manual Test: Add Same File Twice (No Duplication)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that adding the same file twice does not duplicate the asset.

## Prep

Move into the CLI source directory, clean up any previous test run, create a new database and add the PNG file for the first time:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output confirms a new media file database was created in `/tmp/psi-test/source`.
- The first `add` shows `Files added: 1`.

## Test

### 1. Add the same PNG file again

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Already added: 1` and `Files added: 0`.

## Check

### 2. Confirm the database still contains exactly one asset

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected:
- `Files imported:` reports `1`.

---

### 3. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
