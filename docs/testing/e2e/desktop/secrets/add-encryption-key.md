# Desktop Manual Test: Add and Edit an Encryption-Key Secret

Test that the **Add secret** dialog stores an `encryption-key` secret, and that
editing it preserves the raw-PEM format (no JSON envelope is added on
round-trip).

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

## Steps

### 1. Add a new encryption-key secret

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. Type `enc-key-1` into the name field.
4. Set the **Type** to `encryption-key`.
5. Paste the following into the **Private Key PEM** field:

   ```
   -----BEGIN PRIVATE KEY-----
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQ
   -----END PRIVATE KEY-----
   ```
6. Click **Save**.

Expected:
- The dialog closes.
- The Manage Secrets page lists `enc-key-1`.

---

### 2. Confirm the value in the app and the CLI

1. Click the **View secret** (eye) button on the `enc-key-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name enc-key-1 --yes
```

Expected:
- The view dialog shows the PEM you entered.
- The CLI output shows `Type: encryption-key` and the value as the raw PEM string (no JSON envelope around it).

---

### 3. Edit the secret

1. Click the **Edit** button on the `enc-key-1` row.
2. Click **Save** without changing anything.

Expected:
- The dialog closes without errors.

---

### 4. Confirm the edit preserved the raw PEM

1. Click the **View secret** (eye) button on the `enc-key-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name enc-key-1 --yes
```

Expected:
- The view dialog still shows the same PEM.
- The CLI output shows `Type: encryption-key` and the same raw PEM string (no JSON envelope was added on round-trip).
