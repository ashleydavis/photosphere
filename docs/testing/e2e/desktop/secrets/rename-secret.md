# Desktop Manual Test: Rename a Secret

Test that renaming a secret moves the vault file so that the on-disk key
matches the secret's new name.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

Locate the desktop app's vault directory and substitute `<VAULT_DIR>` below.

## Steps

### 1. Seed the vault with a secret named `old-name`

Stop the desktop app, then:

```bash
mkdir -p <VAULT_DIR>
cat > <VAULT_DIR>/old-name.json <<'EOF'
{"name":"old-name","type":"api-key","value":"sk-rename-me"}
EOF
```

Re-start the desktop app.

---

### 2. Edit the secret and change its name

1. Navigate to the **Secrets** page.
2. Click the **Edit** button on the `old-name` row.
3. In the name field, type `new-name`.
4. Click the confirm button.

Expected:
- The dialog closes.

---

### 3. Confirm the vault key matches the new name

```bash
ls <VAULT_DIR>
```

Expected:
- `<VAULT_DIR>/new-name.json` exists.
- `<VAULT_DIR>/old-name.json` no longer exists.
- The value inside `new-name.json` is still `sk-rename-me`.
