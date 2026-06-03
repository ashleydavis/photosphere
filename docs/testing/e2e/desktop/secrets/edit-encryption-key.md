# Desktop Manual Test: Edit an Encryption-Key Secret (Raw PEM)

Test that editing an `encryption-key` secret preserves its raw-PEM format
(no JSON envelope is added on round-trip). This regression was reported as
the Receive-Secret flow producing raw PEMs that crashed when re-edited.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

This walkthrough requires direct access to the app's vault directory. Locate
it on your platform (e.g. `~/.config/photosphere/vault` on Linux) and substitute
`<VAULT_DIR>` below.

## Steps

### 1. Seed the vault with a raw PEM encryption key

Stop the desktop app, then:

```bash
mkdir -p <VAULT_DIR>
cat > <VAULT_DIR>/enc-key-1.json <<'EOF'
{"name":"enc-key-1","type":"encryption-key","value":"-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQ\n-----END PRIVATE KEY-----\n"}
EOF
```

Re-start the desktop app.

---

### 2. Open the Edit dialog for the secret

1. Navigate to the **Manage Secrets** page.
2. Click the **Edit** button on the `enc-key-1` row.

Expected:
- The Edit dialog opens without errors.

---

### 3. Save without making any changes

1. Click the confirm button to save.

Expected:
- The dialog closes.

---

### 4. Confirm the vault still contains the raw PEM

```bash
cat <VAULT_DIR>/enc-key-1.json
```

Expected:
- `type` is still `encryption-key`.
- `value` is still the same raw PEM string (no JSON envelope was added).
