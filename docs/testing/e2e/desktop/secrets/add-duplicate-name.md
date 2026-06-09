# Desktop Manual Test: Add a Secret With a Duplicate Name Fails

Test that adding a second secret with a name that already exists shows an
error and does not overwrite the original.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Add a secret named `dup-secret`

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. Type `dup-secret` into the name field.
4. Fill in any valid value.
5. Click **Save**.

Expected:
- The secret is added and `dup-secret` appears in the list.

---

### 2. Try to add a second secret with the same name

1. Click **Add secret** again.
2. Type `dup-secret` into the name field.
3. Fill in a different value.
4. Click **Save**.

Expected:
- An error is shown (either as a toast or inline in the dialog) along the lines of "A secret named 'dup-secret' already exists".

---

### 3. Confirm the original is untouched

Expected:
- Only one `dup-secret` entry appears in the list.
- Its value is the one from step 1 (the duplicate-add did not overwrite it).
