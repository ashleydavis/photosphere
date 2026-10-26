# CLI Manual Test: Import Directory With Duplicate Content (Dedupe)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that two files with identical content are imported as a single asset.

## Prep

Move into the CLI source directory, clean up any previous test run and create a new database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

## Test

### 1. Add a directory containing two identical images

The repo ships a `test/duplicate-images/` directory with `a.png` and `b.png` (same content, different file names).

```bash
bun run start -- add ../../test/duplicate-images/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows both files processed.

## Check

### 2. Check the database summary

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected:
- `Files imported:` reports `1` (the two source files dedupe to a single asset).

---

### 3. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
