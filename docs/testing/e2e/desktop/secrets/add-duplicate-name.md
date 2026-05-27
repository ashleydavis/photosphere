# Desktop Manual Test: Add a Secret With a Duplicate Name Fails

Test that adding a second secret with a name that already exists shows an
error and does not overwrite the original.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

Locate the desktop app's vault directory and substitute `<VAULT_DIR>` below.

## Steps

### 1. Seed the vault with a secret named `dup-secret`

Stop the desktop app, then:

```bash
mkdir -p <VAULT_DIR>
cat > <VAULT_DIR>/dup-secret.json <<'EOF'
{"name":"dup-secret","type":"s3-credentials","value":"{\"region\":\"\",\"accessKeyId\":\"\",\"secretAccessKey\":\"\"}"}
EOF
```

Note the modification time of the file (for example, with `stat -c%y <VAULT_DIR>/dup-secret.json`).

Re-start the desktop app.

---

### 2. Try to add a second secret with the same name

1. Navigate to the **Secrets** page.
2. Click **Add secret**.
3. Type `dup-secret` into the name field.
4. Click the confirm button.

Expected:
- An error is shown (either as a toast or inline in the dialog) along the lines of "A secret named 'dup-secret' already exists".

---

### 3. Confirm the original file is untouched

```bash
ls <VAULT_DIR>/dup-secret*.json
stat -c%y <VAULT_DIR>/dup-secret.json
```

Expected:
- Exactly one file matches `dup-secret*.json`.
- The modification time is unchanged (the duplicate-add did not overwrite the existing secret).
