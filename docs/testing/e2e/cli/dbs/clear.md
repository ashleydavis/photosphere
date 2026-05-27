# CLI Manual Test: `dbs clear --yes`

Test that `dbs clear --yes` empties the database list entirely.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Point the CLI at an empty config directory

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
```

---

### 2. Seed multiple database entries

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"db-one","description":"","path":"/tmp/psi-test/db-one"},{"name":"db-two","description":"","path":"/tmp/psi-test/db-two"}]
EOF
```

---

### 3. Clear all entries

```bash
bun run start -- dbs clear --yes
```

Expected:
- The command exits successfully.

---

### 4. Confirm the list is empty

```bash
bun run start -- dbs list
```

Expected:
- Output contains `No databases`.
- Output does not contain `db-one` or `db-two`.
