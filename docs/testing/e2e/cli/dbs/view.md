# CLI Manual Test: `dbs view`

Test that `dbs view` shows the full details (name, path, secret IDs) of a
database entry.

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

### 2. Seed a database entry with linked secrets

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"view-db","description":"A test database","path":"/tmp/psi-test/view-db","encryptionKey":"enc00001","s3Key":"s3test01"}]
EOF
```

---

### 3. View the entry

```bash
bun run start -- dbs view --name view-db
```

Expected output contains all of:
- `view-db` (the name).
- `/tmp/psi-test/view-db` (the path).
- `enc00001` (the encryption key id).
- `s3test01` (the S3 credential id).
