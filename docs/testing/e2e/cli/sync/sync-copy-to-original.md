# CLI Manual Test: Sync Copy to Original

Test that `sync` is bidirectional: a file added on the copy side flows back to
the original through the same `sync` command.

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

### 2. Create the original database from the v6 fixture and replicate to a copy

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
```

Expected:
- Replication completes successfully.

---

### 3. Add a new file to the **copy** database

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/copy --yes
```

Expected:
- Output shows `Files added: 1`.

---

### 4. Sync the two databases

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

---

### 5. Confirm the root hashes match

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are identical (the new file added to the copy is now present in the original).
