# CLI Manual Test: `vault list` Showing Shared Secrets

Test that secrets seeded with shared id names appear in `secrets list`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Point the CLI at empty config and vault directories

```bash
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

---

### 2. Seed an S3 credential secret

```bash
cat > /tmp/psi-test/vault/s3test01.json <<'EOF'
{"name":"s3test01","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"secret123\",\"endpoint\":\"http://localhost:9000\"}"}
EOF
```

---

### 3. Seed an API key secret

```bash
cat > /tmp/psi-test/vault/api00001.json <<'EOF'
{"name":"api00001","type":"api-key","value":"AIzaFakeKey123"}
EOF
```

---

### 4. List secrets

```bash
bun run start -- secrets list
```

Expected output contains both:
- `s3test01`.
- `api00001`.
