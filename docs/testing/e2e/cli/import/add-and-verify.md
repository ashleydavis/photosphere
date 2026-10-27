# CLI Manual Test: Add and Verify

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created, a file imported, and the database verified using the CLI.

## Prep

From the repo root, build the CLI, put it on the PATH and clean up any previous test run:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-import-add-and-verify
```

Expected: no output.

## Test

### 1. Create a new database

```bash
psi init --db /tmp/psi-cli-import-add-and-verify/source --yes
```

Expected: Output confirms a new media file database was created in `/tmp/psi-cli-import-add-and-verify/source`.

---

### 2. Import a file

```bash
psi add test/test.jpg --db /tmp/psi-cli-import-add-and-verify/source
```

Expected:
- The file is reported as added.
- No errors are shown.

## Check

### 3. List files in the database

```bash
psi list --db /tmp/psi-cli-import-add-and-verify/source
```

Expected:
- `test.jpg` is listed.

---

### 4. Check that the database is ok

```bash
psi verify --db /tmp/psi-cli-import-add-and-verify/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
