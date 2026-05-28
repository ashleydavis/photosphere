# Desktop Manual Test: Import Video

Test that an MP4 video file can be imported into a Photosphere database using the desktop app.

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
rm -rf /tmp/psi-desktop-video-test
```

---

### 2. Create a new database

1. Open the Photosphere desktop app.
2. Click **Create database** from the File menu or the left side menu.
3. Choose the following as the database directory:
   ```
   /tmp/psi-desktop-video-test/source
   ```
4. Confirm creation.

Expected: The app opens the new empty database with no assets shown.

---

### 3. Import a video file

1. Navigate to the **Import** page.
2. Click **Import files**.
3. Select `test/multiple-files/test.mp4` from the repo root.
4. Wait for the import to complete.

Expected:
- The imported video appears in the gallery with a video thumbnail.
- No error notifications are shown.

---

### 4. List files in the database

```bash
bun run start -- list --db /tmp/psi-desktop-video-test/source
```

Expected:
- `test.mp4` is listed with type `video/mp4`.

---

### 5. Check that the database is ok

```bash
bun run start -- verify --db /tmp/psi-desktop-video-test/source
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.
