# Desktop Manual Test: Edit an S3-Credentials Secret (JSON Envelope)

Test that editing an `s3-credentials` secret updates the changed field, keeps
the other fields, and does not add an extra `label` field.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

Locate the desktop app's vault directory and substitute `<VAULT_DIR>` below.

## Steps

### 1. Seed the vault with an S3 credentials secret

Stop the desktop app, then:

```bash
mkdir -p <VAULT_DIR>
cat > <VAULT_DIR>/s3-creds-1.json <<'EOF'
{"name":"s3-creds-1","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIAOLD\",\"secretAccessKey\":\"OLDSECRET\"}"}
EOF
```

Re-start the desktop app.

---

### 2. Open the Edit dialog and change the region

1. Navigate to the **Secrets** page.
2. Click the **Edit** button on the `s3-creds-1` row.
3. In the region field, type `eu-west-1`.
4. Click the confirm button.

Expected:
- The dialog closes without errors.

---

### 3. Confirm the vault contents

```bash
cat <VAULT_DIR>/s3-creds-1.json
```

The `value` field holds a JSON string. Parse it and check:
- `region` is `eu-west-1` (updated).
- `accessKeyId` is `AKIAOLD` (preserved).
- `secretAccessKey` is `OLDSECRET` (preserved).
- There is no `label` key (the UI must not add one on save).
