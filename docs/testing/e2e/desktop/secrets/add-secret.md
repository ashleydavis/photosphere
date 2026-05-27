# Desktop Manual Test: Add a Secret via the UI

Test that the **Add secret** dialog stores a secret in the vault.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Open the Secrets page

1. Navigate to the **Secrets** page in the desktop app.

Expected:
- The Secrets page loads (it may be empty).

---

### 2. Add a new secret

1. Click **Add secret**.
2. In the dialog, type `test-secret` into the name field.
3. Confirm the dialog.

Expected:
- The dialog closes.
- The Secrets page lists `test-secret`.
- A corresponding `test-secret.json` file exists in the app's vault directory.
