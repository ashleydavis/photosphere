# Desktop Manual Test: Import Directory

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a directory of files can be imported into a Photosphere database using the desktop app.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-import-directory
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-import-directory/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-import-directory/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-import-directory/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-import-directory/logs
export XDG_DATA_HOME=/tmp/psi-desktop-import-directory/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-import-directory/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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

1. Click **New database** from the File menu or the left side menu.
2. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-import-directory/source
   ```
3. Click **Create**.

Expected: The app opens the new empty database with no assets shown.

---

### 2. Import a directory

1. Navigate to the **Import** page.
2. Click **Import directory**.
3. Select the `test/multiple-files/` directory from the repo root.
4. Wait for the import to complete.

The directory holds `test-1.jpeg`, `test-2.png`, `test.mp4` and `test-archive.zip` and the zip holds `PXL_20260322_023611216.mp4` and `test-3.jpg`, so 5 assets are expected.

Expected:
- 5 assets appear in the gallery: the three loose files and the two from inside the zip.
- No error notifications are shown.

## Check

### 3. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-import-directory/source
```

Expected:
- 5 files are listed.

---

### 4. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-import-directory/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks, with `Files imported: 5`.
