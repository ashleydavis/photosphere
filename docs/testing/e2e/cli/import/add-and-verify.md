# CLI Manual Test: Add and Verify

Test that a database can be created, a file imported, and the database verified using the CLI source.

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

### 3. Import a file

```bash
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source
```

Expected:
- The file is reported as added.
- No errors are shown.

---

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test.jpg` is listed.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
