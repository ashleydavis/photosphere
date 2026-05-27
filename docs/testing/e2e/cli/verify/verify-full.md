# CLI Manual Test: Full Verify

Test that `verify --full` performs a deeper integrity scan than the default
quick scan.

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

### 3. Run a quick verify

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.

---

### 4. Run a full verify

```bash
bun run start -- verify --db /tmp/psi-test/source --full
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.
- The output indicates that file hashes were checked (the full verify recomputes each file's hash; the quick verify only checks sizes and merkle metadata).
