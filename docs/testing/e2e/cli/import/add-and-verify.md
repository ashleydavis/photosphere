# CLI Manual Test: Add and Verify

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created, a file imported, and the database verified using the CLI source.

## Prep

Move into the CLI source directory and clean up any previous test run:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
```

Expected: no output.

## Test

### 1. Create a new database

```bash
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-test/source`.

---

### 2. Import a file

```bash
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source
```

Expected:
- The file is reported as added.
- No errors are shown.

## Check

### 3. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test.jpg` is listed.

---

### 4. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
