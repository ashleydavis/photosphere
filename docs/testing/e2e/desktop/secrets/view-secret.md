# Desktop Manual Test: View a Secret Value

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the **View secret** dialog reveals the secret value.

## Prep

Open a terminal at the repo root for the desktop app.

Clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-view-secret
```

Run this in the same terminal. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-view-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-view-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-view-secret/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-view-secret/logs
export XDG_DATA_HOME=/tmp/psi-desktop-view-secret/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-view-secret/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

Start the desktop app in the same terminal, from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a secret to view

1. Navigate to the **Manage Secrets** page in the desktop app.
2. Click **Add secret** (`add-secret-button`), type `smoke-secret` (`secret-name-input`) and confirm (`add-secret-confirm`).

Expected:
- `smoke-secret` is listed.

---

### 2. Open the View dialog

1. Click the **View** button (`view-secret-button`, the `smoke-secret` row) on the `smoke-secret` row.

Expected:
- The View secret dialog opens with the value initially hidden.

## Check

### 3. Reveal the value

1. Click **Reveal** (`reveal-secret-button`) (or the equivalent eye icon).

Expected:
- The secret value is shown.
- No error toasts are visible.
