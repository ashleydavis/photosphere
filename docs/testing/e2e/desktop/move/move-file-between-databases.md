# Desktop Manual Test: Move File Between Databases

Test that a file can be imported into one database and moved to another using the Photosphere desktop app.

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
2. Click **New database** from the File menu or the left side menu.
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

### 4. Create a second database

1. Click **New database** from the File menu or the left side menu.
2. Enter `dest` as the database name.
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-test/dest
   ```
4. Confirm creation.

Expected: The app opens the new empty destination database with no assets shown.

---

### 5. Switch back to the source database

1. Open the left side menu.
2. Click on the **source** database to open it.

Expected: The gallery shows `test.jpg`.

---

### 6. Select the file

1. Select the file by hovering over `test.jpg` and clicking the circle that appears in the top-left corner.

Expected:
- A blue circle with a checkmark appears on the selected file.

---

### 7. Move the file to the destination database

1. Click the **three-dot menu** button (top right of the navbar) to open the right sidebar.
2. Under the **Selection** section, click **Move to dest**.

Expected:
- The file disappears from the source gallery.
- The right sidebar closes.

---

### 8. Open the destination database and check the gallery

1. Open the left side menu.
2. Click on the **dest** database to open it.

Expected:
- The gallery shows `test.jpg`.

---

### 9. Check that the file is no longer in the source database

```bash
bun run start -- list --db /tmp/psi-desktop-test/source
```

Expected:
- No files are listed.

---

### 10. Check that the file is now in the destination database

```bash
bun run start -- list --db /tmp/psi-desktop-test/dest
```

Expected:
- `test.jpg` is listed.
