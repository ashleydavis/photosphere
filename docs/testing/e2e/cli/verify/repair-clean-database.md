# CLI Manual Test: Repair a Clean Database (No Changes)

Test that `repair` is a no-op when the target database has no issues.

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

### 2. Create a database, add a file, then replicate it

```bash
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --yes --force
```

Expected:
- The replica is reported as completed successfully.

---

### 3. Run repair against the clean source using the replica as the recovery source

```bash
bun run start -- repair --db /tmp/psi-test/source --source /tmp/psi-test/replica --yes
```

Expected:
- Output includes `Database repair completed - no issues found`.
- `Repaired:`, `Unrepaired:`, `Modified:`, and `Removed:` all report `0`.

---

### 4. Verify the source database is still intact

```bash
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.
