# Desktop Manual Test: Add and Verify

Test that a database can be created, a file imported, and the database verified using the Photosphere desktop app.

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
3. Choose `/tmp/psi-desktop-test/source` as the database directory.
4. Confirm creation.

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

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-test/source
```

Expected:
- The imported file is listed.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
