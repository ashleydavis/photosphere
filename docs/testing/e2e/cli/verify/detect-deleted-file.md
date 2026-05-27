# CLI Manual Test: Verify Detects a Deleted File

Test that `verify` reports a missing asset file as `Removed`.

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

### 3. Delete one of the asset files from disk

```bash
ls /tmp/psi-test/source/asset
```

Note the UUID, then remove it:

```bash
rm /tmp/psi-test/source/asset/<asset-id>
```

Expected:
- The asset file is gone but the database metadata still references it.

---

### 4. Run verify

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- The command reports that verification found issues.
- `Removed:` reports `1`.
- `Modified:` reports `0`.
