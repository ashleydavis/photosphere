# CLI Manual Test: Sync Original to Copy

Test that `sync` propagates new files added on the original side over to the
copy.

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
- Both databases have the same root hash (confirm with `bun run start -- root-hash` on each path if you wish).

---

### 3. Add a new file to the original database

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/original --yes
```

Expected:
- Output shows `Files added: 1`.

---

### 4. Confirm the root hashes now differ

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are different.

---

### 5. Sync original to copy

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

---

### 6. Confirm the root hashes match again

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are identical.
