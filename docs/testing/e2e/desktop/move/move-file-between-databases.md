# Desktop Manual Test: Move File Between Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a file can be imported into one database and moved to another using the Photosphere desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-move-file-between-databases
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-move-file-between-databases/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-move-file-between-databases/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-move-file-between-databases/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-move-file-between-databases/logs
export XDG_DATA_HOME=/tmp/psi-desktop-move-file-between-databases/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-move-file-between-databases/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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
2. Click **New database** from the File menu or the left side menu.
3. Enter `source` as the database name.
4. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-move-file-between-databases/source
   ```
5. Click **Create**.

Expected: The app opens the new empty database with no assets shown.

---

### 2. Import a file

1. Navigate to the **Import** page.
2. Click **Import photos**.
3. Select `test/test.jpg` from the repo root.
4. Wait for the import to complete.

Expected:
- The imported file appears in the gallery.
- No error notifications are shown.

---

### 3. Create a second database

1. Click **New database** from the File menu or the left side menu.
2. Enter `dest` as the database name.
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-move-file-between-databases/dest
   ```
4. Click **Create**.

Expected: The app opens the new empty destination database with no assets shown.

---

### 4. Switch back to the source database

1. Open the left side menu.
2. Click on the **source** database to open it.

Expected: The gallery shows `test.jpg`.

---

### 5. Select the file

1. Select the file by hovering over `test.jpg` and clicking the circle that appears in the top-left corner.

Expected:
- A blue circle with a checkmark appears on the selected file.

---

### 6. Move the file to the destination database

1. Click the **three-dot menu** button (top right of the navbar) to open the right sidebar.
2. Under the **Selection** section, click **Move to dest**.

Expected:
- The file disappears from the source gallery.
- The right sidebar closes.

---

### 7. Open the destination database and check the gallery

1. Open the left side menu.
2. Click on the **dest** database to open it.

Expected:
- The gallery shows `test.jpg`.

## Check

### 8. Check that the file is no longer in the source database

```bash
bun run start -- list --db /tmp/psi-desktop-move-file-between-databases/source
```

Expected:
- No files are listed.

---

### 9. Check that the file is now in the destination database

```bash
bun run start -- list --db /tmp/psi-desktop-move-file-between-databases/dest
```

Expected:
- `test.jpg` is listed.
