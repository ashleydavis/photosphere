# Desktop Manual Test: Replicate Full Copy

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created, populated, verified and fully replicated to a new directory using the Photosphere desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-replicate-full-copy
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-replicate-full-copy/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-replicate-full-copy/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-replicate-full-copy/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-replicate-full-copy/logs
export XDG_DATA_HOME=/tmp/psi-desktop-replicate-full-copy/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-replicate-full-copy/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, build the CLI and put it on the PATH:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
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
   /tmp/psi-desktop-replicate-full-copy/source
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

### 3. List files in the source database

```bash
psi list --db /tmp/psi-desktop-replicate-full-copy/source
```

Expected:
- The imported file is listed.

---

### 4. Check that the source database is ok

```bash
psi verify --db /tmp/psi-desktop-replicate-full-copy/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 5. Replicate a full copy to a new directory

1. Navigate to the **Manage Databases** (`sidebar-toggle-button`, then `sidebar-manage-databases`) page.
2. Click the **Replicate database** button (`replicate-database-button`, the `source` row) on the source database entry.
3. When prompted for the destination (`replicate-dest-path-input`), enter:
   ```
   /tmp/psi-desktop-replicate-full-copy/replica
   ```
4. When prompted for replication mode, select **Full** (`replicate-mode-full`).
5. Click **Start replication** (`replicate-start-button`) and wait for replication to complete.

Expected:
- A progress indicator is shown during replication.
- A success notification confirms replication completed.

## Check

### 6. List files in the replica database

```bash
psi list --db /tmp/psi-desktop-replicate-full-copy/replica
```

Expected:
- The same file from the source is listed.

---

### 7. Check that the replica database is ok

```bash
psi verify --db /tmp/psi-desktop-replicate-full-copy/replica
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 8. Check the origin of the replica

```bash
psi origin --db /tmp/psi-desktop-replicate-full-copy/replica
```

Expected:
- The origin is shown as:
  ```
  /tmp/psi-desktop-replicate-full-copy/source
  ```
