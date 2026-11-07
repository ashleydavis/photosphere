# Desktop Manual Test: Add a Secret With a Duplicate Name Fails

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that adding a second secret with a name that already exists shows an
error and does not overwrite the original.

## Prep

Open a terminal at the repo root for the desktop app.

Clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-add-duplicate-name
```

Run this in the same terminal. It keeps the test's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-add-duplicate-name/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-add-duplicate-name/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-add-duplicate-name/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-add-duplicate-name/logs
export XDG_DATA_HOME=/tmp/psi-desktop-add-duplicate-name/data
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-add-duplicate-name/data` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

Start the desktop app in the same terminal, from the repo root. Use the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

Expected:
- The cleanup prints nothing.
- The desktop app window opens.

## Test

### 1. Add a secret named `dup-secret`

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret** (`add-secret-button`).
3. Type `dup-secret` into the name field (`secret-name-input`).
4. Fill in any valid value.
5. Click **Save** (`add-secret-confirm`).

Expected:
- The secret is added and `dup-secret` appears in the list.

---

### 2. Try to add a second secret with the same name

1. Click **Add secret** (`add-secret-button`) again.
2. Type `dup-secret` into the name field (`secret-name-input`).
3. Fill in a different value.
4. Click **Save** (`add-secret-confirm`).

Expected:
- An error is shown (either as a toast or inline in the dialog) along the lines of "A secret named 'dup-secret' already exists".

## Check

### 3. Confirm the original is untouched

Expected:
- Only one `dup-secret` entry appears in the list.
- Its value is the one from step 1 (the duplicate-add did not overwrite it).

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Click and type by the `data-id` given in brackets in each step.
- The **Manage Secrets** page has no `data-id` in the steps: reach it with `navigate` and `{"page": "secrets"}`.
