# CLI Manual Test: Remove an Asset by ID

Test that `remove` deletes an asset from the database and from on-disk storage.

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

### 2. Create a database and add a file

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
```

Expected:
- Database created and the file is reported as added.

---

### 3. Read the asset ID from disk

```bash
ls /tmp/psi-test/source/asset
```

Expected:
- One UUID-named file is listed. Record that UUID and use it as `<asset-id>` below.

---

### 4. Remove the asset

```bash
bun run start -- remove --db /tmp/psi-test/source <asset-id> --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.

---

### 5. Confirm the asset files are gone from storage

```bash
ls /tmp/psi-test/source/asset
ls /tmp/psi-test/source/display
ls /tmp/psi-test/source/thumb
```

Expected:
- None of those directories contain `<asset-id>` any more (the directories themselves may exist but be empty).

---

### 6. Confirm the database listing no longer shows the asset

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `<asset-id>` does not appear.

---

### 7. Verify the database

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0` (because the merkle tree has also been updated).
