# CLI Manual Test: Share a Secret Over LAN

Test that `secrets send` and `secrets receive` transfer a secret between two
machines (or two terminals on the same machine).

## Prerequisites

- Two terminals open. Each terminal will run the CLI from `apps/cli/`.
- Both must be on the same LAN.

The sender and receiver each need an isolated vault. The walkthrough below
points each terminal at a different `PHOTOSPHERE_VAULT_DIR` and
`PHOTOSPHERE_CONFIG_DIR`.

## Steps

### 1. Set up the sender

In terminal A:

```bash
cd apps/cli/
rm -rf /tmp/psi-sender
mkdir -p /tmp/psi-sender/config /tmp/psi-sender/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-sender/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-sender/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext

cat > /tmp/psi-sender/vault/test-secret.json <<'EOF'
{"name":"test-secret","type":"api-key","value":"TESTAPIKEY123"}
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
bun run start -- secrets send --name test-secret
```

Expected:
- The command prints a 4-digit pairing code and waits for the receiver to connect.

Record that 4-digit code as `<code>` in the next step.

---

### 4. Start the receiver

In terminal B:

```bash
bun run start -- secrets receive --yes --code <code>
```

Expected:
- The receiver connects to the sender.
- The transfer completes without errors.
- Terminal A reports the share succeeded.

---

### 5. Confirm the secret arrived

In terminal B:

```bash
bun run start -- secrets list
ls /tmp/psi-receiver/vault
```

Expected:
- `secrets list` includes `test-secret`.
- `/tmp/psi-receiver/vault/test-secret.json` exists and contains the value `TESTAPIKEY123`.
