# CLI Manual Test: Add Zip Archive

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a zip archive containing images and a video can be imported into a database using the CLI source. The zip contents should be extracted and each media file imported individually.

## Prep

Move into the CLI source directory, clean up any previous test run and create a new database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

## Test

### 1. Add the zip archive

```bash
bun run start -- add ../../test/multiple-files/test-archive.zip --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 3` and `Files failed: 0`.
- No errors are shown.

## Check

### 2. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test-1.jpeg`, `test-2.png`, and `test.mp4` are each listed as separate assets.

---

### 3. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `3` and `Modified:` reports `0`.
