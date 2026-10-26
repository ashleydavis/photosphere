# Desktop Manual Test: View Database Details Page

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the database details dialog shows the name, path and configured
secrets for a database entry.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-view-database-details
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-view-database-details/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-view-database-details/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-view-database-details/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-view-database-details/logs
export XDG_DATA_HOME=/tmp/psi-desktop-view-database-details/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-view-database-details/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, move into the CLI source directory and pre-create a database:

```bash
cd apps/cli/
bun run start -- init --db /tmp/psi-desktop-view-database-details/db --yes
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a database entry in the desktop app

1. Navigate to the **Manage Databases** page in the desktop app.
2. Click **Add database**.
3. Enter the name `My Test DB` and the path `/tmp/psi-desktop-view-database-details/db`.
4. Click **Add**.

Expected:
- The new entry appears on the Databases page.

## Check

### 2. View the database details

1. From the row for `My Test DB`, click the **View** button.

Expected output contains all of:
- The database name `My Test DB`.
- The database path `/tmp/psi-desktop-view-database-details/db`.
- An asset count (0 for a freshly-created database).
- The configured secret ids (or "none" / equivalent if no secrets were attached).
