# Desktop Manual Test: Remove a Database From the Recent List

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that removing a database from the **Recent databases** sidebar list only
removes the *recent* entry. The underlying database entry must stay
registered in `databases.toml`.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-remove-recent-database
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-remove-recent-database/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-remove-recent-database/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-remove-recent-database/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-remove-recent-database/logs
export XDG_DATA_HOME=/tmp/psi-desktop-remove-recent-database/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-remove-recent-database/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, build the CLI, put it on the PATH and pre-create two databases:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
psi init --db /tmp/psi-desktop-remove-recent-database/db-a --yes
psi init --db /tmp/psi-desktop-remove-recent-database/db-b --yes
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Register both databases and open both at least once

1. In the desktop app, register both databases (Databases page (`sidebar-toggle-button`, then `sidebar-manage-databases`) → Add database (`add-database-button`))
   so they show up in `databases.toml`.
2. Open each one at least once so both appear in **Recent databases**.

Expected:
- Both `db-a` and `db-b` appear in the Recent databases section of the left sidebar.

---

### 2. Remove one of the recent entries

1. Open the left sidebar (`sidebar-toggle-button`).
2. Click the trash / remove icon next to `db-a` in the Recent databases list.

Expected:
- `db-a` disappears from the Recent databases list.
- `db-b` is still in the list.

## Check

### 3. Confirm the underlying database entry survives

```bash
grep -E "db-a|db-b" /tmp/psi-desktop-remove-recent-database/config/databases.toml
```

Expected:
- Both `db-a` and `db-b` are still listed as `[[databases]]` entries.
- Only `db-a` is missing from the `recent_database_names` array.

---

### 4. Restart the app and confirm the change persists

1. Quit the desktop app.
2. Start it again in the same terminal, so the exports from Prep still apply, with `bun run linux` from the repo root (or `macos` or `windows`, for the platform you are on).
3. Open the left sidebar (`sidebar-toggle-button`).

Expected:
- `db-a` is still gone from the Recent databases list.
- `db-b` is still in the Recent databases list.
