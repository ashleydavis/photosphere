# CLI Manual Test: Share a Database Entry Over LAN

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs send` and `dbs receive` transfer a database configuration plus
its linked secrets from one CLI to another.

Two terminals are needed, each running the CLI from `apps/cli/`, both on the same LAN.

## Prep

In terminal A, set up the sender with a database entry and a linked secret:

```bash
cd apps/cli/
rm -rf /tmp/psi-sender
mkdir -p /tmp/psi-sender/config /tmp/psi-sender/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-sender/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-sender/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-sender/vault/vault.json <<'EOF'
{"test-s3-key":{"name":"test-s3-key","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"testsecret\"}"}}
EOF
cat > /tmp/psi-sender/config/databases.toml <<'EOF'
recent_database_names = []

[[databases]]
name = "test-db"
description = ""
path = "/tmp/psi-sender/test-db"
s3_key = "test-s3-key"
EOF
```

In terminal B, set up the receiver:

```bash
cd apps/cli/
rm -rf /tmp/psi-receiver
mkdir -p /tmp/psi-receiver/config /tmp/psi-receiver/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-receiver/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-receiver/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

Expected: no output in either terminal.

## Test

### 1. Start the sender

In terminal A:

```bash
bun run start -- dbs send --name test-db --yes
```

Expected:
- The command shows the database to send, prints a 4-digit pairing code and waits for the receiver.

Record the pairing code as `<code>` for the next step.

---

### 2. Start the receiver

In terminal B:

```bash
bun run start -- dbs receive --yes --code <code>
```

Expected:
- The receiver connects to the sender and pulls the database entry and the
  linked secret.
- Terminal A reports that the share succeeded.

## Check

### 3. Confirm the database entry and secret arrived

In terminal B:

```bash
bun run start -- dbs list
bun run start -- secrets list
```

Expected:
- `dbs list` contains `test-db` and its path.
- `secrets list` contains `test-s3-key`.
- `/tmp/psi-receiver/vault/vault.json` holds a `test-s3-key` key.
