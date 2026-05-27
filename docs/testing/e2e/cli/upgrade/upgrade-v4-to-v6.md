# CLI Manual Test: Upgrade v4 Database to v6

Test that `upgrade` brings a v4 database to the current schema version (6).

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

### 2. Copy the v4 fixture to a working directory

```bash
cp -r ../../test/dbs/v4 /tmp/psi-test/upgrade
```

---

### 3. Run upgrade

```bash
bun run start -- upgrade --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output includes `Database upgraded successfully to version 6`.

---

### 4. Confirm the upgraded version

```bash
bun run start -- summary --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output contains `Database version: 6`.

---

### 5. Verify the upgraded database

```bash
bun run start -- verify --db /tmp/psi-test/upgrade --yes
```

Expected:
- Output contains `Database verification passed`.
