# Desktop Manual Test: Edit a Database's Origin Path

Test that the desktop app's Edit dialog can change a database entry's origin
and that the new value is persisted to `.db/config.json`.

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

### 2. Pre-create a database with the CLI

```bash
bun run start -- init --db /tmp/psi-desktop-test/db --yes
```

---

### 3. Add the database to the app and open the Edit dialog

1. Navigate to the **Databases** page in the desktop app.
2. Click **Add database**, enter `My Test DB` and `/tmp/psi-desktop-test/db`, save.
3. Click the **Edit** button for the row.

Expected:
- The Edit dialog opens with the current name, path, and origin shown.

---

### 4. Change the origin and save

1. In the Edit dialog's **Origin** field, type `s3:my-bucket:/origin-database`.
2. Click **Save**.

Expected:
- The dialog closes and the entry is updated.

---

### 5. Confirm the new origin was written to disk

```bash
cat /tmp/psi-desktop-test/db/.db/config.json
```

Expected:
- The `origin` field in the JSON is `s3:my-bucket:/origin-database`.
