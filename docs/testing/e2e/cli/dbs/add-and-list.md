# CLI Manual Test: `dbs add` Then `dbs list`

Test that adding an entry makes it appear in the listing.

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

### 2. Add a database entry by directly seeding `databases.json`

The smoke-test runner uses a `seed_databases_config` helper. The manual
equivalent is to write the file directly:

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"smoke-db","description":"Smoke test database","path":"/tmp/psi-test/smoke-db"}]
EOF
```

Expected:
- The file exists and contains the JSON above.

---

### 3. List databases

```bash
bun run start -- dbs list
```

Expected:
- Output contains `smoke-db`.
- Output contains `/tmp/psi-test/smoke-db`.
