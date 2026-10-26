# CLI Manual Test: Add MP4 Video

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that an MP4 video file can be added to a database using the CLI source.

## Prep

Move into the CLI source directory, clean up any previous test run and create a new database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

## Test

### 1. Add the MP4 file

```bash
bun run start -- add ../../test/multiple-files/test.mp4 --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 1` and `Files failed: 0`.
- No errors are shown.

## Check

### 2. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test.mp4` is listed with type `video/mp4`.

---

### 3. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `1` and `Modified:` reports `0`.
