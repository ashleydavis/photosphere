# CLI Manual Test: Add Multiple Files

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that multiple files can be imported in a single `add` command.

## Prep

Move into the CLI source directory, clean up any previous test run and create a new database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

## Test

### 1. Add a directory containing multiple files

The repo ships a `test/multiple-files/` directory holding `test-1.jpeg`, `test-2.png`, `test.mp4`, and a `test-archive.zip`. The zip contains the same files, so they are skipped as duplicates.

```bash
bun run start -- add ../../test/multiple-files/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 3` and `Files failed: 0`.

## Check

### 2. Confirm all files are now in the database

```bash
bun run start -- check ../../test/multiple-files/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Already added: 3`.

---

### 3. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `3`.
