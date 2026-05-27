# CLI Manual Test: Resolve Database by Name

Test that `--db <name>` resolves through `databases.json` and auto-loads the
linked encryption key from the shared vault.

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
bun run start -- init --db /tmp/psi-test/db --key dbs-enc-key --generate-key --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --key dbs-enc-key --yes
```

Expected:
- The database is initialised and the asset is added.
- The vault file `/tmp/psi-test/vault/dbs-enc-key.json` exists.

---

### 3. Republish the encryption key under a shared id

```bash
bun -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync('/tmp/psi-test/vault/dbs-enc-key.json','utf8'));fs.writeFileSync('/tmp/psi-test/vault/enc00001.json',JSON.stringify({name:'enc00001',type:'encryption-key',value:d.value}));"
```

Expected:
- The new vault file `/tmp/psi-test/vault/enc00001.json` exists.

---

### 4. Register the database with the shared key id

```bash
cat > /tmp/psi-test/config/databases.json <<'EOF'
[{"name":"resolve-name-db","description":"","path":"/tmp/psi-test/db","encryptionKey":"enc00001"}]
EOF
```

---

### 5. Run `summary` by database name

```bash
bun run start -- summary --db resolve-name-db --yes
```

Expected:
- The command exits successfully (the encryption key was auto-resolved through `databases.json`).
- The summary output reflects the one previously-added asset (`Files imported: 1`).
