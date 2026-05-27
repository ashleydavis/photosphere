# CLI Manual Test: Add Multiple Files

Test that multiple files can be imported in a single `add` command.

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

### 3. Add a directory containing multiple files

The repo ships a `test/multiple-images/` directory holding `test-1.jpeg` and `test-2.png`.

```bash
bun run start -- add ../../test/multiple-images/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 2` and `Files failed: 0`.

---

### 4. Confirm all files are now in the database

```bash
bun run start -- check ../../test/multiple-images/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Already added: 2`.

---

### 5. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Files imported:` reports `2`.
