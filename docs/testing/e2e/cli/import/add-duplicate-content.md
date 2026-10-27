# CLI Manual Test: Import Directory With Duplicate Content (Dedupe)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that two files with identical content are imported as a single asset.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and create a new database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-duplicate-content
psi init --db /tmp/psi-cli-import-add-duplicate-content/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-duplicate-content/source`.

## Test

### 1. Add a directory containing two identical images

The repo ships a `test/duplicate-images/` directory with `a.png` and `b.png` (same content, different file names).

```bash
psi add test/duplicate-images/ --db /tmp/psi-cli-import-add-duplicate-content/source --yes
```

Expected:
- Output shows both files processed.

## Check

### 2. Check the database summary

```bash
psi summary --db /tmp/psi-cli-import-add-duplicate-content/source
```

Expected:
- `Files imported:` reports `1` (the two source files dedupe to a single asset).

---

### 3. Verify the database

```bash
psi verify --db /tmp/psi-cli-import-add-duplicate-content/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
