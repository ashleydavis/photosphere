# CLI Manual Test: `dbs edit` (Rename)

Test that `dbs edit --new-name` renames a database entry.

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

### 2. Seed a database entry

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"edit-db","description":"","path":"/tmp/psi-test/edit-db"}]
EOF
```

---

### 3. Rename it

```bash
bun run start -- dbs edit --name edit-db --yes --new-name renamed-db
```

Expected:
- The command exits successfully.

---

### 4. Confirm the new name is listed

```bash
bun run start -- dbs list
```

Expected:
- Output contains `renamed-db`.
- Output does not contain `edit-db`.
