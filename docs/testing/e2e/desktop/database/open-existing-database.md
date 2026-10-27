# Desktop Manual Test: Open an Existing Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the desktop app can open a database that was created with the CLI.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-open-existing-database
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-open-existing-database/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-open-existing-database/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-open-existing-database/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-open-existing-database/logs
export XDG_DATA_HOME=/tmp/psi-desktop-open-existing-database/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-open-existing-database/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, build the CLI, put it on the PATH and create a database with one asset in it:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
psi init --db /tmp/psi-desktop-open-existing-database/source --yes
psi add test/test.jpg --db /tmp/psi-desktop-open-existing-database/source --yes
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.
- Output confirms a new media file database was created in `/tmp/psi-desktop-open-existing-database/source`.
- The asset is reported as added.

## Test

### 1. Open the database in the desktop app

1. Click **Open database** (`no-database-open-database` on the startup screen, `sidebar-toggle-button` then `sidebar-open-database` in the left side menu). It is on the startup screen (when no database is
   loaded), in the left side menu and in the **File > Open Database...** menu
   (Ctrl/Cmd+O). All of these open the **Open Database** dialog.
2. The **Open Database** dialog lists databases you have already configured.
   Since this database was just created with the CLI, it will not be listed yet,
   so click **Add database** (`open-database-modal-add-database`) to register it.
3. In the **Add Database** dialog:
   - **Name** (`database-name-input`): enter a name (for example `desktop-test`).
   - **Type** (`database-storage-type-select`): leave as **File system**.
   - **Path** (`database-path-input`): click **Browse** (`database-browse-button`) and select `/tmp/psi-desktop-open-existing-database/source`, or
     type the path directly.
   - Click **Add** (`add-database-confirm`). This registers the database and opens it.

Expected:
- The database opens and the gallery view appears, showing the previously-imported asset.
- No error toasts are shown.

## Check

### 2. Confirm the database is healthy from the CLI

```bash
psi verify --db /tmp/psi-desktop-open-existing-database/source
```

Expected:
- Verification completes without errors.
