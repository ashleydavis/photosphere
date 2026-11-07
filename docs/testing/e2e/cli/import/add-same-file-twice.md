# CLI Manual Test: Add Same File Twice (No Duplication)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that adding the same file twice does not duplicate the asset.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a new database and add the PNG file for the first time:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-same-file-twice
psi init --db /tmp/psi-cli-import-add-same-file-twice/source --yes
psi add test/test.png --db /tmp/psi-cli-import-add-same-file-twice/source --yes
```

Expected:
- Output confirms a new media file database was created in `/tmp/psi-cli-import-add-same-file-twice/source`.
- The first `add` shows `Files added: 1`.

## Test

### 1. Add the same PNG file again

```bash
psi add test/test.png --db /tmp/psi-cli-import-add-same-file-twice/source --yes
```

Expected:
- Output shows `Already added: 1` and `Files added: 0`.

## Check

### 2. Confirm the database still contains exactly one asset

```bash
psi summary --db /tmp/psi-cli-import-add-same-file-twice/source
```

Expected:
- `Files imported:` reports `1`.

---

### 3. Verify the database

```bash
psi verify --db /tmp/psi-cli-import-add-same-file-twice/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
