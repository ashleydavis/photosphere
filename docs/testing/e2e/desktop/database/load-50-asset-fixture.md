# Desktop Manual Test: Load the 50-Asset Fixture

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the desktop app loads the repo's pre-populated 50-asset database and
renders the gallery with all assets visible.

## Prep

Open a terminal at the repo root for the desktop app.

Clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-load-50-asset-fixture
```

Run this in the same terminal. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-load-50-asset-fixture/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-load-50-asset-fixture/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-load-50-asset-fixture/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-load-50-asset-fixture/logs
export XDG_DATA_HOME=/tmp/psi-desktop-load-50-asset-fixture/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-load-50-asset-fixture/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

Start the desktop app in the same terminal, from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Open the fixture in the desktop app

1. Click **Open database** (`no-database-open-database` on the startup screen, `sidebar-toggle-button` then `sidebar-open-database` in the left side menu). It is on the startup screen (when no database is
   loaded), in the left side menu and in the **File > Open Database...** menu
   (Ctrl/Cmd+O). All of these open the **Open Database** dialog.
2. The **Open Database** dialog lists databases you have already configured.
   - If `50-assets` is already listed, click it and skip to the expected result.
   - Otherwise click **Add database** (`open-database-modal-add-database`) to register it first.
3. In the **Add Database** dialog:
   - **Name** (`database-name-input`): enter `50-assets`.
   - **Type** (`database-storage-type-select`): leave as **File system**.
   - **Path** (`database-path-input`): click **Browse** (`database-browse-button`) and select `test/dbs/50-assets/` (relative to
     the repo root), or type the path directly.
   - Click **Add** (`add-database-confirm`). This registers the database and opens it.

Expected:
- The gallery loads and displays exactly 50 thumbnails.
- No error toasts are shown.

## Check

### 2. Spot-check that thumbnails and previews render

- Scroll through the gallery and confirm the thumbnails are visible.
- Click on any asset (`gallery-thumb`) to open its detail view and confirm the larger preview renders.

Expected:
- All 50 thumbnails are visible (no broken-image placeholders).
- The detail view opens for each asset clicked, showing a larger preview and metadata.
