# Desktop Manual Test: Import Zip Archive

Test that a zip archive containing images and a video can be imported into a Photosphere database using the desktop app. The zip contents should be extracted and each media file imported individually.

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
rm -rf /tmp/psi-desktop-zip-test
```

---

### 2. Create a new database

1. Open the Photosphere desktop app.
2. Click **Create database** from the File menu or the left side menu.
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-zip-test/source
   ```
4. Confirm creation.

Expected: The app opens the new empty database with no assets shown.

---

### 3. Import the zip archive

1. Navigate to the **Import** page.
2. Click **Import files**.
3. Select `test/multiple-files/test-archive.zip` from the repo root.
4. Wait for the import to complete.

Expected:
- All three assets from the zip (`test-1.jpeg`, `test-2.png`, `test.mp4`) appear in the gallery.
- No error notifications are shown.

---

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-zip-test/source
```

Expected:
- `test-1.jpeg`, `test-2.png`, and `test.mp4` are each listed as separate assets.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-zip-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
