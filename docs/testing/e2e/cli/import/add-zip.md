# CLI Manual Test: Add Zip Archive

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a zip archive containing an image and a video can be imported into a database using the CLI. The zip contents should be extracted and each media file imported individually.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-zip
psi init --db /tmp/psi-cli-import-add-zip/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-zip/source`.

## Test

### 1. Add the zip archive

```bash
psi add test/multiple-files/test-archive.zip --db /tmp/psi-cli-import-add-zip/source --yes
```

Expected:
- Output shows `Files added: 2` and `Files failed: 0`.
- No errors are shown.

## Check

### 2. List files in the database

```bash
psi list --db /tmp/psi-cli-import-add-zip/source
```

Expected:
- `PXL_20260322_023611216.mp4` and `test-3.jpg` are each listed as separate assets.

---

### 3. Check that the database is ok

```bash
psi verify --db /tmp/psi-cli-import-add-zip/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `2` and `Modified:` reports `0`.
