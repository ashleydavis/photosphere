# Desktop Manual Test: Replicate Full Copy

Test that a database can be created, populated, verified, and fully replicated to a new directory using the Photosphere desktop app.

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
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-test/source
   ```
4. Click **Create**.

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

### 4. List files in the source database

```bash
bun run start -- list --db /tmp/psi-desktop-test/source
```

Expected:
- The imported file is listed.

---

### 5. Check that the source database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 6. Replicate a full copy to a new directory

1. Navigate to the **Manage Databases** page.
2. Click the **Replicate database** button on the source database entry.
3. When prompted for the destination, enter:
   ```
   /tmp/psi-desktop-test/replica
   ```
4. When prompted for replication mode, select **Full**.
5. Click **Start replication** and wait for replication to complete.

Expected:
- A progress indicator is shown during replication.
- A success notification confirms replication completed.

---

### 7. List files in the replica database

```bash
bun run start -- list --db /tmp/psi-desktop-test/replica
```

Expected:
- The same file from the source is listed.

---

### 8. Check that the replica database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-test/replica
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 9. Check the origin of the replica

```bash
bun run start -- origin --db /tmp/psi-desktop-test/replica
```

Expected:
- The origin is shown as:
  ```
  /tmp/psi-desktop-test/source
  ```
