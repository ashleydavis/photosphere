# CLI Manual Test: Add Multiple Files

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that multiple files can be imported in a single `add` command.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-multiple-files
psi init --db /tmp/psi-cli-import-add-multiple-files/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-multiple-files/source`.

## Test

### 1. Add a directory containing multiple files

The repo ships a `test/multiple-files/` directory holding `test-1.jpeg`, `test-2.png`, `test.mp4` and a `test-archive.zip`. The zip holds two more files, `PXL_20260322_023611216.mp4` and `test-3.jpg`, which differ from the others, so five files are imported in all.

```bash
psi add test/multiple-files/ --db /tmp/psi-cli-import-add-multiple-files/source --yes
```

Expected:
- Output shows `Files added: 5` and `Files failed: 0`.

## Check

### 2. Confirm all files are now in the database

```bash
psi check test/multiple-files/ --db /tmp/psi-cli-import-add-multiple-files/source --yes
```

Expected:
- Output shows `Already added: 5`.

---

### 3. Verify the database

```bash
psi verify --db /tmp/psi-cli-import-add-multiple-files/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `5`.
