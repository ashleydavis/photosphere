# CLI Manual Test: Add PNG File

Test that a PNG file can be added to a database using the CLI source.

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

### 3. Add the PNG file

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 1` and `Files failed: 0`.
- No errors are shown.

---

### 4. Check that the PNG file is in the database

```bash
bun run start -- check ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Already added: 1`.

---

### 5. List files in the database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test.png` is listed with type `image/png`.

---

### 6. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `1` and `Modified:` reports `0`.
