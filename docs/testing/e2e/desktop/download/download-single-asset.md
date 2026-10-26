# Desktop Manual Test: Download Single Asset

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a single asset can be downloaded to a local folder from the asset view in the Photosphere desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test and create the download folder:

```bash
rm -rf /tmp/psi-desktop-download-single-asset
mkdir -p /tmp/psi-desktop-download-single-asset/downloads
```

The save dialog in step 4 can only save into a folder that already exists, so the `downloads` folder must be created up front.

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-download-single-asset/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-download-single-asset/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-download-single-asset/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-download-single-asset/logs
export XDG_DATA_HOME=/tmp/psi-desktop-download-single-asset/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-download-single-asset/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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

### 1. Create a new database

1. Open the Photosphere desktop app.
2. Click **New database** (`sidebar-toggle-button`, then `sidebar-new-database`) from the File menu or the left side menu.
3. Enter `source` (`database-name-input`) as the database name.
4. Choose the following as the database directory (`database-path-input`):
   ```
   /tmp/psi-desktop-download-single-asset/source
   ```
5. Click **Create** (`create-database-confirm`).

Expected: The app opens the new empty database with no assets shown.

---

### 2. Import a file

1. Navigate to the **Import** (`navbar-import-button`) page.
2. Click **Import files** (`import-files-button`).
3. Select `test/test.jpg` from the repo root.
4. Wait for the import to complete.

Expected:
- The imported file appears in the gallery.
- No error notifications are shown.

---

### 3. Open the asset view

1. In the gallery, click the imported `test.jpg` thumbnail (`gallery-thumb`).

Expected:
- The asset view drawer slides open showing the full-resolution image.

---

### 4. Download the asset

1. In the asset view toolbar, click the **Download** icon (`download-asset-button`) (the down-arrow icon next to **Copy to clipboard**).
2. In the save dialog, set the destination to the `downloads` folder created in Prep:
   - Press **Ctrl+L** to open the path entry field (plain typing triggers search within the current folder instead).
   - Type the full destination path including the filename and press Enter:
     ```
     /tmp/psi-desktop-download-single-asset/downloads/test.jpg
     ```
3. Click **Save** to confirm.

Expected:
- A success toast appears with the message `Downloaded "test.jpg"` and an **Open Folder** action.
- No error notifications are shown.

## Check

### 5. Verify the file exists on disk

```bash
ls -la /tmp/psi-desktop-download-single-asset/downloads
```

Expected:
- `test.jpg` is listed.
- The file size is non-zero and matches the original.

---

### 6. Verify the file content

```bash
file /tmp/psi-desktop-download-single-asset/downloads/test.jpg
```

Expected:
- The file is identified as a JPEG image.
