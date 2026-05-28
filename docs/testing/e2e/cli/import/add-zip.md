# CLI Manual Test: Add Zip Archive

Test that a zip archive containing images and a video can be imported into a database using the CLI source. The zip contents should be extracted and each media file imported individually.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
```

---

### 2. Create a new database

```bash
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

---

### 3. Add the zip archive

```bash
bun run start -- add ../../test/multiple-files/test-archive.zip --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 3` and `Files failed: 0`.
- No errors are shown.

---

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test-1.jpeg`, `test-2.png`, and `test.mp4` are each listed as separate assets.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `3` and `Modified:` reports `0`.
