# Desktop Manual Test: Open an Existing Database

Test that the desktop app can open a database that was created with the CLI.

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

### 2. Create a database from the CLI

```bash
bun run start -- init --db /tmp/psi-desktop-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-desktop-test/source --yes
```

Expected:
- Output confirms a new media file database was created in `/tmp/psi-desktop-test/source`.
- The asset is reported as added.

---

### 3. Open the database in the desktop app

1. Click **Open database**. It is on the startup screen (when no database is
   loaded), in the left side menu, and in the **File > Open Database...** menu
   (Ctrl/Cmd+O). All of these open the **Open Database** dialog.
2. The **Open Database** dialog lists databases you have already configured.
   Since this database was just created with the CLI, it will not be listed yet,
   so click **Add database** to register it.
3. In the **Add Database** dialog:
   - **Name**: enter a name (for example `desktop-test`).
   - **Type**: leave as **File system**.
   - **Path**: click **Browse** and select `/tmp/psi-desktop-test/source`, or
     type the path directly.
   - Click **Add**. This registers the database and opens it.

Expected:
- The database opens and the gallery view appears, showing the previously-imported asset.
- No error toasts are shown.

---

### 4. Confirm the database is healthy from the CLI

```bash
bun run start -- verify --db /tmp/psi-desktop-test/source
```

Expected:
- Verification completes without errors.
