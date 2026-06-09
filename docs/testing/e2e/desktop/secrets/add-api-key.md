# Desktop Manual Test: Add and Edit an API-Key Secret

Test that the **Add secret** dialog stores an `api-key` secret, and that editing
it round-trips the raw key value (no JSON envelope is added).

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Add a new api-key secret

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. Type `api-key-1` into the name field.
4. Set the **Type** to `api-key`.
5. Type `sk-test-1234567890ABCDEF` into the **API Key** field.
6. Click **Save**.

Expected:
- The dialog closes.
- The Manage Secrets page lists `api-key-1`.

---

### 2. Confirm the value in the app and the CLI

1. Click the **View secret** (eye) button on the `api-key-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name api-key-1 --yes
```

Expected:
- The view dialog shows the value `sk-test-1234567890ABCDEF`.
- The CLI output shows `Type: api-key` and `Value: sk-test-1234567890ABCDEF` (the raw string, with no JSON envelope around it).

---

### 3. Edit the secret

1. Click the **Edit** button on the `api-key-1` row.
2. Change the **API Key** field to `sk-test-CHANGED-99999`.
3. Click **Save**.

Expected:
- The dialog closes.

---

### 4. Confirm the edit in the app and the CLI

1. Click the **View secret** (eye) button on the `api-key-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name api-key-1 --yes
```

Expected:
- The view dialog shows the updated value `sk-test-CHANGED-99999`.
- The CLI output shows `Value: sk-test-CHANGED-99999` as a raw string (no JSON envelope was added on round-trip).
