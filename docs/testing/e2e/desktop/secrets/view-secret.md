# Desktop Manual Test: View a Secret Value

Test that the **View secret** dialog reveals the secret value.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Add a secret to view

1. Navigate to the **Secrets** page in the desktop app.
2. Click **Add secret**, type `smoke-secret`, and confirm.

Expected:
- `smoke-secret` is listed.

---

### 2. Open the View dialog

1. Click the **View** button on the `smoke-secret` row.

Expected:
- The View secret dialog opens with the value initially hidden.

---

### 3. Reveal the value

1. Click **Reveal** (or the equivalent eye icon).

Expected:
- The secret value is shown.
- No error toasts are visible.
