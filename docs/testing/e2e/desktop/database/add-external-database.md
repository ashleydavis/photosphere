# Desktop Manual Test: Link an External Database Into the App

Test that an existing CLI-created database can be added to the desktop app's
Databases list and then opened.

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

### 2. Create a database with the CLI

```bash
bun run start -- init --db /tmp/psi-desktop-test/external-db --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-desktop-test/external-db --yes
```

Expected:
- The database is created and the asset is reported as added.

---

### 3. Link the external database from the app

1. Navigate to the **Databases** page in the desktop app.
2. Click **Add database**.
3. Enter the name `External DB` and the path `/tmp/psi-desktop-test/external-db`.
4. Save the entry.

Expected:
- The new entry appears on the Databases page.

---

### 4. Open the external database

1. From the Databases page, open the `External DB` entry.

Expected:
- The gallery loads and shows the previously-imported asset.
- No error toasts are shown.
