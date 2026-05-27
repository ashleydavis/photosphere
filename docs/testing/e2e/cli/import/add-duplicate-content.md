# CLI Manual Test: Import Directory With Duplicate Content (Dedupe)

Test that two files with identical content are imported as a single asset.

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

### 3. Add a directory containing two identical images

The repo ships a `test/duplicate-images/` directory with `a.png` and `b.png` (same content, different file names).

```bash
bun run start -- add ../../test/duplicate-images/ --db /tmp/psi-test/source --yes
```

Expected:
- Output shows both files processed.

---

### 4. Check the database summary

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected:
- `Files imported:` reports `1` (the two source files dedupe to a single asset).

---

### 5. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
