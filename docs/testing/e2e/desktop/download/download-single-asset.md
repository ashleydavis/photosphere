# Desktop Manual Test: Download Single Asset

Test that a single asset can be downloaded to a local folder from the asset view in the Photosphere desktop app.

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

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-desktop-test
```

---

### 2. Create a new database

1. Open the Photosphere desktop app.
2. Click **Create database** from the File menu or the left side menu.
3. Enter `source` as the database name.
4. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-test/source
   ```
5. Confirm creation.

Expected: The app opens the new empty database with no assets shown.

---

### 3. Import a file

1. Navigate to the **Import** page.
2. Click **Import photos**.
3. Select `test/test.jpg` from the repo root.
4. Wait for the import to complete.

Expected:
- The imported file appears in the gallery.
- No error notifications are shown.

---

### 4. Open the asset view

1. In the gallery, click the imported `test.jpg` thumbnail.

Expected:
- The asset view drawer slides open showing the full-resolution image.

---

### 5. Download the asset

1. In the asset view toolbar, click the **Download** icon (the down-arrow icon next to **Copy to clipboard**).
2. In the save dialog, choose the following destination:
   ```
   /tmp/psi-desktop-test/downloads/test.jpg
   ```
3. Confirm the save.

Expected:
- A success toast appears with the message `Downloaded "test.jpg"` and an **Open Folder** action.
- No error notifications are shown.

---

### 6. Verify the file exists on disk

```bash
ls -la /tmp/psi-desktop-test/downloads
```

Expected:
- `test.jpg` is listed.
- The file size is non-zero and matches the original.

---

### 7. Verify the file content

```bash
file /tmp/psi-desktop-test/downloads/test.jpg
```

Expected:
- The file is identified as a JPEG image.
