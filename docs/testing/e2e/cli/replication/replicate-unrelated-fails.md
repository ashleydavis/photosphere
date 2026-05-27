# CLI Manual Test: Replication Between Unrelated Databases Fails

Test that `replicate` refuses to overwrite a destination that belongs to a
different database.

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

### 2. Create two independent databases

```bash
bun run start -- init --db /tmp/psi-test/first --yes
bun run start -- init --db /tmp/psi-test/second --yes
```

Expected:
- Both databases are created.

---

### 3. Confirm the two databases have different IDs

```bash
bun run start -- database-id --db /tmp/psi-test/first --yes
bun run start -- database-id --db /tmp/psi-test/second --yes
```

Expected:
- The two UUIDs are different.

---

### 4. Attempt to replicate the first over the second

```bash
bun run start -- replicate --db /tmp/psi-test/first --dest /tmp/psi-test/second --yes
```

Expected:
- The command exits with a non-zero status.
- The error message contains `different ID than the source database` and `not related to the source database`.
- It prints both the source and destination database IDs.
