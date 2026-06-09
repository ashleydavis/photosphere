# Desktop Manual Test: Remove a Database From the Recent List

Test that removing a database from the **Recent databases** sidebar list only
removes the *recent* entry — the underlying database entry must stay
registered in `databases.toml`.

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

### 2. Pre-create two databases and open both at least once

```bash
bun run start -- init --db /tmp/psi-desktop-test/db-a --yes
bun run start -- init --db /tmp/psi-desktop-test/db-b --yes
```

1. In the desktop app, register both databases (Databases page → Add database)
   so they show up in `databases.toml`.
2. Open each one at least once so both appear in **Recent databases**.

Expected:
- Both `db-a` and `db-b` appear in the Recent databases section of the left sidebar.

---

### 3. Remove one of the recent entries

1. Open the left sidebar.
2. Click the trash / remove icon next to `db-a` in the Recent databases list.

Expected:
- `db-a` disappears from the Recent databases list.
- `db-b` is still in the list.

---

### 4. Confirm the underlying database entry survives

```bash
grep -E "test-db-a|test-db-b" "$(find ~/.config -name databases.toml 2>/dev/null | head -1)"
```

(Use whichever config directory the desktop app writes to on your platform.)

Expected:
- Both `db-a` and `db-b` are still listed as `[[databases]]` entries.
- Only `db-a` is missing from the `recent_database_names` array.

---

### 5. Restart the app and confirm the change persists

1. Quit the desktop app.
2. Start it again with `bun run dev`.
3. Open the left sidebar.

Expected:
- `db-a` is still gone from the Recent databases list.
- `db-b` is still in the Recent databases list.
