# Desktop Manual Test: View a Database Secret from the View Database Modal

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a secret linked to a database can be drilled into and revealed from
within the **View Database** modal.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-view-database-secret
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-view-database-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-view-database-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-view-database-secret/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-view-database-secret/logs
export XDG_DATA_HOME=/tmp/psi-desktop-view-database-secret/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-view-database-secret/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, move into the CLI source directory and pre-create a database:

```bash
cd apps/cli/
bun run start -- init --db /tmp/psi-desktop-view-database-secret/db --yes
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add the database to the app

1. Navigate to the **Manage Databases** page in the desktop app.
2. Click **Add database**, enter `My Test DB` and `/tmp/psi-desktop-view-database-secret/db`, then click **Add**.

Expected:
- The new entry appears on the Databases page.

---

### 2. Link a secret to the database

1. Click the **Edit** button for the `My Test DB` row.
2. Click **Configure secrets…**.
3. On the **Geocoding API Key** row, click **+ New**.
4. In the create-secret dialog, enter the name `smoke-geocoding` and the value `test-api-key-12345`, then click **Create**.
5. Confirm `smoke-geocoding` is now selected in the Geocoding API Key dropdown, then click **Save**.
6. Back in the Edit dialog, click **Save**.

Expected:
- The dialogs close without errors and the entry is updated.

## Check

### 3. Open the View Database modal

1. From the row for `My Test DB`, click the **View** button.

Expected:
- The **View Database** modal opens.
- The **Linked Secrets** section shows **Geocoding API Key** with the name `smoke-geocoding` and a **View Secret** button.

---

### 4. Drill into the linked secret

1. Click the **View Secret** button on the Geocoding API Key row.

Expected:
- A nested **View Secret** dialog opens for `smoke-geocoding`.
- The value is initially hidden (shown as `••••••••••`).

---

### 5. Reveal the secret value

1. Click **Reveal**.

Expected:
- The API key value `test-api-key-12345` is shown.
- No error toasts are visible.
