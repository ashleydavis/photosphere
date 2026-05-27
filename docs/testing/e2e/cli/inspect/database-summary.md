# CLI Manual Test: Database Summary

Test that `summary` reports the expected fields for a populated database.

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

### 3. Show the database summary

```bash
bun run start -- summary --db /tmp/psi-test/source
```

Expected output contains all of these fields:
- `Files imported:` (1 for the one added asset).
- `Total files:` (multiple, including display/thumb and metadata derivatives).
- `Total size:` in bytes or human-readable form.
- `Full root hash:` showing the aggregate root hash of the database.
