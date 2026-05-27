# CLI Manual Test: Share a Database Entry Over LAN

Test that `dbs send` and `dbs receive` transfer a database configuration plus
its linked secrets from one CLI to another.

## Prerequisites

- Two terminals open. Each terminal will run the CLI from `apps/cli/`.
- Both must be on the same LAN.

## Steps

### 1. Set up the sender with a database entry and linked secrets

In terminal A:

```bash
cd apps/cli/
rm -rf /tmp/psi-sender
mkdir -p /tmp/psi-sender/config /tmp/psi-sender/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-sender/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-sender/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext

cat > /tmp/psi-sender/vault/test-s3-key.json <<'EOF'
{"name":"test-s3-key","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"testsecret\"}"}
EOF

cat > /tmp/psi-sender/config/databases.json <<'EOF'
[{"name":"test-db","description":"","path":"/tmp/psi-sender/test-db","s3Key":"test-s3-key"}]
EOF
```

---

### 2. Set up the receiver

In terminal B:

```bash
cd apps/cli/
rm -rf /tmp/psi-receiver
mkdir -p /tmp/psi-receiver/config /tmp/psi-receiver/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-receiver/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-receiver/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

---

### 3. Start the sender

In terminal A:

```bash
bun run start -- dbs send --name test-db
```

Expected:
- The command prints a 4-digit pairing code and waits for the receiver.

Record the pairing code as `<code>` for the next step.

---

### 4. Start the receiver

In terminal B:

```bash
bun run start -- dbs receive --yes --code <code>
```

Expected:
- The receiver connects to the sender and pulls the database entry and the
  linked secret.
- Terminal A reports that the share succeeded.

---

### 5. Confirm the database entry and secret arrived

In terminal B:

```bash
bun run start -- dbs list
bun run start -- secrets list
```

Expected:
- `dbs list` contains `test-db` and its path.
- `secrets list` contains `test-s3-key`.
- `/tmp/psi-receiver/vault/test-s3-key.json` exists.
