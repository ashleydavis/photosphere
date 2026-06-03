# Desktop Manual Test: Download Multiple Assets

Test that multiple selected assets can be downloaded to a local folder from the right sidebar in the Photosphere desktop app.

## Prerequisites

Start the desktop app from source (run from the repo root):

```bash
bun run dev
```

CLI commands are run from `apps/cli/`:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run and create the download folder

```bash
rm -rf /tmp/psi-desktop-test
mkdir -p /tmp/psi-desktop-test/downloads
```

The folder picker in step 6 can only select a folder that already exists, so the `downloads` folder must be created up front.

---

### 2. Create a new database

1. Open the Photosphere desktop app.
2. Click **New database** from the File menu or the left side menu.
3. Enter `source` as the database name.
4. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-test/source
   ```
5. Confirm creation.

Expected: The app opens the new empty database with no assets shown.

---

### 3. Import multiple files

1. Navigate to the **Import** page.
2. Click **Import photos**.
3. Select two or more files from the `test/multiple-files/` directory in the repo root (for example `test-1.jpeg` and `test-2.png`).
4. Wait for the imports to complete.

Expected:
- All imported files appear in the gallery.
- No error notifications are shown.

---

### 4. Select multiple assets

1. Hover over the first thumbnail and click the circle that appears in the top-left corner to select it.
2. Repeat for the second thumbnail.

Expected:
- A blue circle with a checkmark appears on each selected file.

---

### 5. Open the right sidebar

1. Click the **three-dot menu** button (top right of the navbar) to open the right sidebar.

Expected:
- The right sidebar opens and shows a **Selection** section with the selected asset count.

---

### 6. Download the selected assets

1. In the **Selection** section, click **Download N assets** (where N matches the number selected).
2. In the folder picker, navigate to the `downloads` folder created in step 1:
   - Press **Ctrl+L** to open the path entry field (plain typing triggers search within the current folder instead).
   - Type the parent path and press Enter:
     ```
     /tmp/psi-desktop-test/
     ```
   - Single-click the `downloads` folder to select it (do not double-click, which navigates into it).
3. Click **Open** to confirm the choice.

Expected:
- A success toast appears with the message `Downloaded N assets`.
- No error notifications are shown.

---

### 7. Verify the files exist on disk

```bash
ls -la /tmp/psi-desktop-test/downloads
```

Expected:
- Each selected asset is listed using its original filename.
- File sizes are non-zero and match the originals.

---

### 8. Verify the file content

```bash
file /tmp/psi-desktop-test/downloads/*
```

Expected:
- Each file is identified as the correct image or video type.
