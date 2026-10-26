# Desktop Manual Test: Add and Edit an API-Key Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the **Add secret** dialog stores an `api-key` secret and that editing
and saving it keeps the key value exactly as entered.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-add-api-key
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-add-api-key/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-add-api-key/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-add-api-key/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-add-api-key/logs
export XDG_DATA_HOME=/tmp/psi-desktop-add-api-key/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-add-api-key/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, move into the CLI source directory:

```bash
cd apps/cli/
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a new api-key secret

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret** (`add-secret-button`).
3. Type `api-key-1` into the name field (`secret-name-input`).
4. Set the **Type** (`secret-type-select`) to `api-key` (`secret-type-option-api-key`).
5. Type `sk-test-1234567890ABCDEF` into the **API Key** field (`secret-value-input`).
6. Click **Save** (`add-secret-confirm`).

Expected:
- The dialog closes.
- The Manage Secrets page lists `api-key-1`.

---

### 2. Confirm the value in the app and the CLI

1. Click the **View secret** (eye) button (`view-secret-button`, the `api-key-1` row) on the `api-key-1` row.
2. Click **Reveal** (`reveal-secret-button`) to show the value.

Then run in the CLI terminal:

```bash
bun run start -- secrets view --name api-key-1 --yes
```

Expected:
- The view dialog shows the value `sk-test-1234567890ABCDEF`.
- The CLI output shows `Type: api-key` and `Value: sk-test-1234567890ABCDEF`, the exact string you entered.

---

### 3. Edit the secret

1. Click the **Edit** button (`edit-secret-button`, the `api-key-1` row) on the `api-key-1` row.
2. Change the **API Key** field (`secret-value-input`) to `sk-test-CHANGED-99999`.
3. Click **Save** (`add-secret-confirm`).

Expected:
- The dialog closes.

## Check

### 4. Confirm the edit in the app and the CLI

1. Click the **View secret** (eye) button (`view-secret-button`, the `api-key-1` row) on the `api-key-1` row.
2. Click **Reveal** (`reveal-secret-button`) to show the value.

Then run in the CLI terminal:

```bash
bun run start -- secrets view --name api-key-1 --yes
```

Expected:
- The view dialog shows the updated value `sk-test-CHANGED-99999`.
- The CLI output shows `Value: sk-test-CHANGED-99999`, the exact string you entered, unchanged.
