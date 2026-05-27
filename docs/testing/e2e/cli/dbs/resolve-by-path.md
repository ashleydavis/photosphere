# CLI Manual Test: Resolve Database by Path

Test that passing `--db <path>` resolves to the matching entry in
`databases.json` and auto-loads the linked encryption key.

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

### 2. Initialise an encrypted database with a generated key

```bash
bun run start -- init --db /tmp/psi-test/db --key dbs-path-enc-key --generate-key --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --key dbs-path-enc-key --yes
```

Expected:
- The database is initialised and the asset is added.

---

### 3. Republish the encryption key under a shared id

```bash
bun -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync('/tmp/psi-test/vault/dbs-path-enc-key.json','utf8'));fs.writeFileSync('/tmp/psi-test/vault/enc00002.json',JSON.stringify({name:'enc00002',type:'encryption-key',value:d.value}));"
```

---

### 4. Register the database with the shared key id

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"resolve-path-db","description":"","path":"/tmp/psi-test/db","encryptionKey":"enc00002"}]
EOF
```

---

### 5. Run `summary` by path (the encryption key should auto-resolve)

```bash
bun run start -- summary --db /tmp/psi-test/db --yes
```

Expected:
- The command exits successfully (the linked encryption key was loaded automatically via the path lookup).
- The summary output reflects the previously-added asset.
