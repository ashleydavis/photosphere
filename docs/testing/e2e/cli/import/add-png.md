# CLI Manual Test: Add PNG File

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a PNG file can be added to a database using the CLI.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-png
psi init --db /tmp/psi-cli-import-add-png/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-png/source`.

## Test

### 1. Add the PNG file

```bash
psi add test/test.png --db /tmp/psi-cli-import-add-png/source --yes
```

Expected:
- Output shows `Files added: 1` and `Files failed: 0`.
- No errors are shown.

## Check

### 2. Check that the PNG file is in the database

```bash
psi check test/test.png --db /tmp/psi-cli-import-add-png/source --yes
```

Expected:
- Output shows `Already added: 1`.

---

### 3. List files in the database

```bash
psi list --db /tmp/psi-cli-import-add-png/source
```

Expected:
- `test.png` is listed with type `image/png`.

---

### 4. Check that the database is ok

```bash
psi verify --db /tmp/psi-cli-import-add-png/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `1` and `Modified:` reports `0`.
