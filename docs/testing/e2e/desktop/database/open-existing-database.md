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
```

Expected: Output confirms a new media file database was created in `/tmp/psi-desktop-test/source`.

---

### 3. Open the database in the desktop app

1. In the desktop app, choose **Open database** from the File menu (or the left side menu).
2. Browse to `/tmp/psi-desktop-test/source` and open it.

Expected:
- The database opens and the gallery view appears (it will be empty until assets are imported).
- No error toasts are shown.

---

### 4. Confirm the database is healthy from the CLI

```bash
bun run start -- verify --db /tmp/psi-desktop-test/source
```

Expected:
- Verification completes without errors.
