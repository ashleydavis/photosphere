# Desktop Manual Test: View Database Details Page

Test that the database details dialog shows the name, path, and configured
secrets for a database entry.

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

### 3. Add a database entry in the desktop app

1. Navigate to the **Manage Databases** page in the desktop app.
2. Click **Add database**.
3. Enter the name `My Test DB` and the path `/tmp/psi-desktop-test/db`.
4. Click **Add**.

Expected:
- The new entry appears on the Databases page.

---

### 4. View the database details

1. From the row for `My Test DB`, click the **View** button.

Expected output contains all of:
- The database name `My Test DB`.
- The database path `/tmp/psi-desktop-test/db`.
- An asset count (0 for a freshly-created database).
- The configured secret ids (or "none" / equivalent if no secrets were attached).
