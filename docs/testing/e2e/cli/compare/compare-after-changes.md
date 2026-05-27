# CLI Manual Test: Compare After Changes

Test that `compare` detects differences when one database is ahead of the other.

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
- Source and replica are identical at this point.

---

### 3. Add a second file to the source only

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/source --yes
```

Expected:
- Output shows `Files added: 1`.

---

### 4. Compare source and replica

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- Output reports a non-zero number of differences (typically `Databases have 3 differences` because adding one asset adds the original, display, and thumb entries to the merkle tree).
