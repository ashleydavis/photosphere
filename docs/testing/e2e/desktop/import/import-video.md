# Desktop Manual Test: Import Video

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that an MP4 video file can be imported into a Photosphere database using the desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-import-video
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-import-video/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-import-video/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-import-video/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-import-video/logs
export XDG_DATA_HOME=/tmp/psi-desktop-import-video/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-import-video/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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
3. Choose the following as the database directory (`database-path-input`):
   ```
   /tmp/psi-desktop-import-video/source
   ```
4. Click **Create** (`create-database-confirm`).

Expected: The app opens the new empty database with no assets shown.

---

### 2. Import a video file

1. Navigate to the **Import** (`navbar-import-button`) page.
2. Click **Import files** (`import-files-button`).
3. Select `test/multiple-files/test.mp4` from the repo root.
4. Wait for the import to complete.

Expected:
- The imported video appears in the gallery with a video thumbnail.
- Check that the video plays.
- No error notifications are shown.

## Check

### 3. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-import-video/source
```

Expected:
- `test.mp4` is listed with type `video/mp4`.

---

### 4. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-import-video/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
