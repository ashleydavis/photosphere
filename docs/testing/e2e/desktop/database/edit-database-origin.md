# Desktop Manual Test: Edit a Database's Origin Path

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the desktop app's Edit dialog can change a database entry's origin
and that the new value is persisted to `.db/config.json`.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-edit-database-origin
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-edit-database-origin/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-edit-database-origin/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-edit-database-origin/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-edit-database-origin/logs
export XDG_DATA_HOME=/tmp/psi-desktop-edit-database-origin/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-edit-database-origin/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

In the CLI terminal, build the CLI, put it on the PATH and pre-create a database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
psi init --db /tmp/psi-desktop-edit-database-origin/db --yes
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add the database to the app and open the Edit dialog

1. Navigate to the **Manage Databases** (`sidebar-toggle-button`, then `sidebar-manage-databases`) page in the desktop app.
2. Click **Add database** (`add-database-button`), enter `My Test DB` (`database-name-input`) and `/tmp/psi-desktop-edit-database-origin/db` (`database-path-input`), then click **Add** (`add-database-confirm`).
3. Click the **Edit** button (`edit-database-button`, the `My Test DB` row) for the row.

Expected:
- The Edit dialog opens with the current name, path and origin shown.

---

### 2. Check the origin before the change with the CLI

```bash
psi origin --db /tmp/psi-desktop-edit-database-origin/db
```

Expected:
- The output is `(not set)` (a freshly initialised database has no origin).

---

### 3. Change the origin and save

1. In the Edit dialog's **Origin** field (`database-origin-input`), type `s3:my-bucket/origin-database`.
2. Click **Save** (`save-database-button`).

Expected:
- The dialog closes and the entry is updated.

## Check

### 4. Check the origin after the change with the CLI

```bash
psi origin --db /tmp/psi-desktop-edit-database-origin/db
```

Expected:
- The output is `s3:my-bucket/origin-database`.

---

### 5. Confirm the new origin was written to disk

```bash
cat /tmp/psi-desktop-edit-database-origin/db/.db/config.json
```

Expected:
- The `origin` field in the JSON is `s3:my-bucket/origin-database`.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Click and type by the `data-id` given in brackets in each step.
