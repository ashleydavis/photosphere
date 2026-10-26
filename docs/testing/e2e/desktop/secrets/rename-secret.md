# Desktop Manual Test: Rename a Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that renaming a secret stores it under the new name, so it is found by the
new name and no longer by the old one, with its value preserved.

## Prep

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-rename-secret
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-rename-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-rename-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-rename-secret/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-rename-secret/logs
export XDG_DATA_HOME=/tmp/psi-desktop-rename-secret/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-rename-secret/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

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

### 1. Add a secret named `old-name`

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret** (`add-secret-button`).
3. Type `old-name` into the name field (`secret-name-input`).
4. Set the **Type** (`secret-type-select`) to `api-key` (`secret-type-option-api-key`).
5. Type `sk-rename-me` into the value field (`secret-value-input`).
6. Click **Save** (`add-secret-confirm`).

Expected:
- The Manage Secrets page lists `old-name`.

---

### 2. Edit the secret and change its name

1. Navigate to the **Manage Secrets** page.
2. Click the **Edit** button (`edit-secret-button`, the `old-name` row) on the `old-name` row.
3. In the name field (`secret-name-input`), type `new-name`.
4. Click **Save** (`add-secret-confirm`).

Expected:
- The dialog closes.

## Check

### 3. Confirm the secret was renamed

In the app:
- The **Manage Secrets** page lists `new-name`.
- `old-name` no longer appears.

With the CLI, run in the CLI terminal:

```bash
bun run start -- secrets list
```

Expected:
- `secrets list` shows a `new-name` row with `api-key` in its Type column, and no `old-name` row.
