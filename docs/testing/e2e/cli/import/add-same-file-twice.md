# CLI Manual Test: Add Same File Twice (No Duplication)

Test that adding the same file twice does not duplicate the asset.

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

### 3. Add the PNG file for the first time

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 1`.

---

### 4. Add the same PNG file again

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Already added: 1` and `Files added: 0`.

---

### 5. Confirm the database still contains exactly one asset

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected:
- `Files imported:` reports `1`.

---

### 6. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0`.
