# Desktop Manual Test: Edit an API-Key Secret

Test that editing an `api-key` secret round-trips the raw key value (no JSON
envelope is added).

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

Locate the desktop app's vault directory and substitute `<VAULT_DIR>` below.

## Steps

### 1. Seed the vault with a raw API key

Stop the desktop app, then:

```bash
mkdir -p <VAULT_DIR>
cat > <VAULT_DIR>/api-key-1.json <<'EOF'
{"name":"api-key-1","type":"api-key","value":"sk-test-1234567890ABCDEF"}
EOF
```

Re-start the desktop app.

---

### 2. Open the Edit dialog for the secret

1. Navigate to the **Secrets** page.
2. Click the **Edit** button on the `api-key-1` row.

Expected:
- The Edit dialog opens without errors.

---

### 3. Save without making any changes

1. Click the confirm button.

Expected:
- The dialog closes.

---

### 4. Confirm the vault value is unchanged

```bash
cat <VAULT_DIR>/api-key-1.json
```

Expected:
- `value` is still the original raw string `sk-test-1234567890ABCDEF` (no JSON envelope around it).
