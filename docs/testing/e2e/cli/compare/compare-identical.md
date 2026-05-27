# CLI Manual Test: Compare Two Identical Databases

Test that `compare` reports no differences for two identical databases.

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
- Replica is reported as completed successfully.

---

### 3. Compare source and replica

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes
```

Expected:
- Output includes `No differences detected`.

---

### 4. Compare a database with itself

```bash
bun run start -- compare --db /tmp/psi-test/source --dest /tmp/psi-test/source --yes
```

Expected:
- Output includes `No differences detected`.
