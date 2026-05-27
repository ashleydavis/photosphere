# CLI Manual Test: Verify Detects a Modified File

Test that `verify` reports a tampered asset file as `Modified`.

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

### 3. Tamper with one of the asset files

```bash
ls /tmp/psi-test/source/asset
```

Note the UUID, then append data to it (do not delete):

```bash
echo "tampered" >> /tmp/psi-test/source/asset/<asset-id>
```

Expected:
- The asset file is now larger and its content differs from the recorded hash.

---

### 4. Run verify

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- The command reports that verification found issues.
- `Modified:` reports `1`.
- `Removed:` reports `0`.
