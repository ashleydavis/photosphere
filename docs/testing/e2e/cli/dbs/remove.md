# CLI Manual Test: `dbs remove --yes`

Test that `dbs remove --yes` removes a database entry from the list and leaves
the other entries untouched.

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

### 2. Seed two database entries

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"keep-db","description":"","path":"/tmp/psi-test/keep-db"},{"name":"remove-db","description":"","path":"/tmp/psi-test/remove-db"}]
EOF
```

---

### 3. Remove one entry

```bash
bun run start -- dbs remove --name remove-db --yes
```

Expected:
- The command exits successfully.

---

### 4. Confirm the listing

```bash
bun run start -- dbs list
```

Expected:
- Output contains `keep-db`.
- Output does not contain `remove-db`.
