# CLI Manual Test: Add MP4 Video

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that an MP4 video file can be added to a database using the CLI.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-mp4
psi init --db /tmp/psi-cli-import-add-mp4/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-mp4/source`.

## Test

### 1. Add the MP4 file

```bash
psi add test/multiple-files/test.mp4 --db /tmp/psi-cli-import-add-mp4/source --yes
```

Expected:
- Output shows `Files added: 1` and `Files failed: 0`.
- No errors are shown.

## Check

### 2. List files in the database

```bash
psi list --db /tmp/psi-cli-import-add-mp4/source
```

Expected:
- `test.mp4` is listed with type `video/mp4`.

---

### 3. Check that the database is ok

```bash
psi verify --db /tmp/psi-cli-import-add-mp4/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `1` and `Modified:` reports `0`.
