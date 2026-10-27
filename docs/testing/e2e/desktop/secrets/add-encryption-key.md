# Desktop Manual Test: Add and Edit an Encryption-Key Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the **Add secret** dialog stores an `encryption-key` secret and that
editing and saving it keeps the PEM value exactly as entered.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-add-encryption-key
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-add-encryption-key/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-add-encryption-key/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-add-encryption-key/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-add-encryption-key/logs
export XDG_DATA_HOME=/tmp/psi-desktop-add-encryption-key/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-add-encryption-key/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a new encryption-key secret

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret** (`add-secret-button`).
3. Type `enc-key-1` into the name field (`secret-name-input`).
4. Set the **Type** (`secret-type-select`) to `encryption-key` (`secret-type-option-encryption-key`).
5. Paste the following into the **Private Key PEM** field (`secret-private-key-input`):

   ```
   -----BEGIN PRIVATE KEY-----
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQ
   -----END PRIVATE KEY-----
   ```
6. Click **Save** (`add-secret-confirm`).

Expected:
- The dialog closes.
- The Manage Secrets page lists `enc-key-1`.

---

### 2. Confirm the value in the app and the CLI

1. Click the **View secret** (eye) button (`view-secret-button`, the `enc-key-1` row) on the `enc-key-1` row.
2. Click **Reveal** (`reveal-secret-button`) to show the value.

Then run in the CLI terminal:

```bash
psi secrets view --name enc-key-1 --yes
```

Expected:
- The view dialog shows the PEM you entered.
- The CLI output shows `Type: encryption-key` and the value as the exact PEM string you entered.

---

### 3. Edit the secret so a write is forced

If you save without changing anything, the app may skip the write entirely, so
the check below would prove nothing. So this step changes the PEM before
saving, which guarantees the value is written again.

1. Click the **Edit** button (`edit-secret-button`, the `enc-key-1` row) on the `enc-key-1` row.
2. Clear the **Private Key PEM** field (`secret-private-key-input`) and paste this different key in its place:

   ```
   -----BEGIN PRIVATE KEY-----
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAA
   MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAB
   -----END PRIVATE KEY-----
   ```
3. Click **Save** (`add-secret-confirm`).

Expected:
- The dialog closes without errors.

## Check

### 4. Confirm the edit kept the PEM exactly

The edit in step 3 forced a real write, so this confirms saving did not
change the PEM value.

1. Click the **View secret** (eye) button (`view-secret-button`, the `enc-key-1` row) on the `enc-key-1` row.
2. Click **Reveal** (`reveal-secret-button`) to show the value.

Then run in the CLI terminal:

```bash
psi secrets view --name enc-key-1 --yes
```

Expected:
- The view dialog shows the replacement PEM you pasted in step 3, byte-for-byte.
- The CLI output shows `Type: encryption-key` and that same PEM string, unchanged.
