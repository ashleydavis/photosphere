# CLI Manual Test: Replicate Partial Copy

Test that a database can be created, populated, verified, and partially replicated to a new directory using the CLI source.

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
mkdir -p /tmp/psi-test/source
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

### 4. List files in the source database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- `test.jpg` is listed.

---

### 5. Check that the source database is ok

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 6. Replicate a partial copy to a new directory

```bash
mkdir -p /tmp/psi-test/replica
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --partial --yes
```

Expected:
- Replication results show files copied.
- `✅ Replication completed successfully` is shown.

---

### 7. List files in the replica database

```bash
bun run start -- list --db /tmp/psi-test/replica
```

Expected:
- `test.jpg` is listed.

> **Note:** This is not currently working.

---

### 8. Check that the replica database is ok

```bash
bun run start -- verify --db /tmp/psi-test/replica
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 9. Check the origin of the replica

```bash
bun run start -- origin --db /tmp/psi-test/replica
```

Expected:
- The origin is shown as `/tmp/psi-test/source`.
