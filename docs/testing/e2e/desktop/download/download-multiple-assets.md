# Desktop Manual Test: Download Multiple Assets

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that multiple selected assets can be downloaded to a local folder from the right sidebar in the Photosphere desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test and create the download folder:

```bash
rm -rf /tmp/psi-desktop-download-multiple-assets
mkdir -p /tmp/psi-desktop-download-multiple-assets/downloads
```

The folder picker in step 5 can only select a folder that already exists, so the `downloads` folder must be created up front.

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-download-multiple-assets/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-download-multiple-assets/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-download-multiple-assets/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-download-multiple-assets/logs
export XDG_DATA_HOME=/tmp/psi-desktop-download-multiple-assets/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-download-multiple-assets/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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
   /tmp/psi-desktop-download-multiple-assets/source
   ```
5. Click **Create** (`create-database-confirm`).

Expected: The app opens the new empty database with no assets shown.

---

### 2. Import multiple files

1. Navigate to the **Import** (`navbar-import-button`) page.
2. Click **Import files** (`import-files-button`).
3. Select two or more files from the `test/multiple-files/` directory in the repo root (for example `test-1.jpeg` and `test-2.png`).
4. Wait for the imports to complete.

Expected:
- All imported files appear in the gallery.
- No error notifications are shown.

---

### 3. Select multiple assets

1. Hover over the first thumbnail and click the circle (`gallery-item-checkbox`) that appears in the top-left corner to select it.
2. Repeat for the second thumbnail.

Expected:
- A blue circle with a checkmark appears on each selected file.

---

### 4. Open the right sidebar

1. Click the **three-dot menu** button (`right-sidebar-button`) (top right of the navbar) to open the right sidebar.

Expected:
- The right sidebar opens and shows a **Selection** section with the selected asset count.

---

### 5. Download the selected assets

1. In the **Selection** section, click **Download N assets** (`download-selected-button`) (where N matches the number selected).
2. In the folder picker, navigate to the `downloads` folder created in Prep:
   - Press **Ctrl+L** to open the path entry field (plain typing triggers search within the current folder instead).
   - Type the parent path and press Enter:
     ```
     /tmp/psi-desktop-download-multiple-assets/
     ```
   - Single-click the `downloads` folder to select it (do not double-click, which navigates into it).
3. Click **Open** to confirm the choice.

Expected:
- A success toast appears with the message `Downloaded N assets`.
- No error notifications are shown.

## Check

### 6. Verify the files exist on disk

```bash
ls -la /tmp/psi-desktop-download-multiple-assets/downloads
```

Expected:
- Each selected asset is listed using its original filename.
- File sizes are non-zero and match the originals.

---

### 7. Verify the file content

```bash
file /tmp/psi-desktop-download-multiple-assets/downloads/*
```

Expected:
- Each file is identified as the correct image or video type.
