# Desktop Manual Test: Import Directory

Test that a directory of files can be imported into a Photosphere database using the desktop app.

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
rm -rf /tmp/psi-desktop-dir-test
```

---

### 2. Create a new database

1. Open the Photosphere desktop app.
2. Click **New database** from the File menu or the left side menu.
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-dir-test/source
   ```
4. Click **Create**.

Expected: The app opens the new empty database with no assets shown.

---

### 3. Import a directory

1. Navigate to the **Import** page.
2. Click **Import directory**.
3. Select the `test/multiple-files/` directory from the repo root.
4. Wait for the import to complete.

Expected:
- All files from the directory appear in the gallery.
- No error notifications are shown.

---

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-dir-test/source
```

Expected:
- All imported files are listed.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-dir-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
