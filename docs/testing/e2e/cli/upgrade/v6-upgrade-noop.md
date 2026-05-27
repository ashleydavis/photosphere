# CLI Manual Test: Upgrading a v6 Database Is a No-Op

Test that running `upgrade` on a v6 database reports that no upgrade is needed
and leaves the database unchanged.

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

### 2. Copy the v6 fixture to a working directory

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/upgrade
```

---

### 3. Run upgrade

```bash
bun run start -- upgrade --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output includes `Database is already at the latest version (6)`.

---

### 4. Confirm version and integrity

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes
bun run start -- verify --db /tmp/psi-test/upgrade --yes
```

Expected:
- Summary contains `Database version: 6`.
- Verify reports `Database verification passed`.
