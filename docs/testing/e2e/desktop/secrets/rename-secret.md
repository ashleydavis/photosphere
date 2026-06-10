# Desktop Manual Test: Rename a Secret

Test that renaming a secret stores it under the new name, so it is found by the
new name and no longer by the old one, with its value preserved.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Add a secret named `old-name`

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. Type `old-name` into the name field.
4. Set the **Type** to `api-key`.
5. Type `sk-rename-me` into the value field.
6. Click **Save**.

Expected:
- The Manage Secrets page lists `old-name`.

---

### 2. Edit the secret and change its name

1. Navigate to the **Manage Secrets** page.
2. Click the **Edit** button on the `old-name` row.
3. In the name field, type `new-name`.
4. Click **Save**.

Expected:
- The dialog closes.

---

### 3. Confirm the secret was renamed

In the app:
- The **Manage Secrets** page lists `new-name`.
- `old-name` no longer appears.

With the CLI, run from the repo root:

```bash
bun run start -- secrets list
```

Expected:
- `secrets list` shows `new-name` with `Type: api-key`, and does not show `old-name`.
