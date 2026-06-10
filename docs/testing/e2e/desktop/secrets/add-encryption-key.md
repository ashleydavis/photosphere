# Desktop Manual Test: Add and Edit an Encryption-Key Secret

Test that the **Add secret** dialog stores an `encryption-key` secret, and that
editing and saving it keeps the PEM value exactly as entered.

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
- The CLI output shows `Type: encryption-key` and the value as the exact PEM string you entered.

---

### 3. Edit the secret so a write is forced

If you save without changing anything, the app may skip the write entirely, so
the check below would prove nothing. So this step changes the PEM before
saving, which guarantees the value is written again.

1. Click the **Edit** button on the `enc-key-1` row.
2. Clear the **Private Key PEM** field and paste this different key in its place:

   ```
   -----BEGIN PRIVATE KEY-----
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAA
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAB
   -----END PRIVATE KEY-----
   ```
3. Click **Save**.

Expected:
- The dialog closes without errors.

---

### 4. Confirm the edit kept the PEM exactly

The edit in step 3 forced a real write, so this confirms saving did not
change the PEM value.

1. Click the **View secret** (eye) button on the `enc-key-1` row.

Then run from the repo root:

```bash
bun run start -- secrets view --name enc-key-1 --yes
```

Expected:
- The view dialog shows the replacement PEM you pasted in step 3, byte-for-byte.
- The CLI output shows `Type: encryption-key` and that same PEM string, unchanged.
