# CLI Manual Test: Cannot Create Database Over Existing

Test that `init` refuses to overwrite an existing database directory.

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

### 3. Attempt to create a second database in the same directory

```bash
bun run start -- init --db /tmp/psi-test/source --yes
```

Expected:
- The command exits with a non-zero status.
- An error message indicates the database directory already contains a database.

---

### 4. Confirm the original database is intact

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- The database is still readable and intact.
