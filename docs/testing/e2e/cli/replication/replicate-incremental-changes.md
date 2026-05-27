# CLI Manual Test: Replicate Incremental Changes

Test that re-replicating after adding files to the source copies just the new
files.

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

### 2. Create a database, add a file, and replicate it

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Replication completes successfully.

---

### 3. Add a new file to the source

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 1`.

---

### 4. Re-replicate

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- Output includes `Replication completed successfully`.
- `Total files copied:` reports a small non-zero value (typically `3` — original, display, and thumb for the one new asset).

---

### 5. Confirm the databases are equivalent again

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- Output includes `No differences detected`.
- The root hashes for source and replica match.
