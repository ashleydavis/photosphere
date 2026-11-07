# Desktop Manual Test: Share a Database Entry Over LAN

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that the desktop app can share a database entry (with its linked secrets)
from one instance to another.

## Prep

You need two desktop instances that can see each other over the local network.
The simplest way is to run two isolated copies on the same machine, each
pointed at its own folders so they do not share state or the OS keychain.

The app is started with the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`, from the repo root. The commands below use `linux`.

Open two terminals at the repo root: terminal A for the **sender** and terminal B for the **receiver**.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-share-database
```

Start the **sender** in terminal A:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-share-database/sender/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-share-database/sender/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-share-database/sender/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-share-database/sender/logs
export XDG_DATA_HOME=/tmp/psi-desktop-share-database/sender/data
bun run linux
```

Start the **receiver** in terminal B:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-share-database/receiver/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-share-database/receiver/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-share-database/receiver/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-share-database/receiver/logs
export XDG_DATA_HOME=/tmp/psi-desktop-share-database/receiver/data
bun run linux
```

Each block keeps that instance's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in its own folder, away from the other instance, from other tests and from a normal install. Two copies on one machine need separate data folders, otherwise the second copy is refused by the one-copy lock.

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-share-database/sender/data` (and `.../receiver/data` for the receiver) in its place. On macOS the app's data cannot be moved this way, so two copies cannot run on one machine: quit any other copy of Photosphere and run the sender and receiver on two machines.

Notes:
- `PHOTOSPHERE_CONFIG_DIR` isolates each instance's database/secret config.
- `PHOTOSPHERE_VAULT_DIR` isolates each instance's vault file.
- `PHOTOSPHERE_VAULT_TYPE=plaintext` stores every secret in a single
  `vault.json` under the vault directory, keyed by secret name, instead of in
  the shared OS keychain, so the two instances stay independent (and you can
  inspect the vault file directly).

Both instances run on the same machine and discover each other over local
loopback. (Two separate machines on the same LAN also works; run one command
per machine.)

The sender starts empty. Step 1 below seeds it with a database entry and its
linked secret(s).

Expected:
- The cleanup prints nothing.
- Both desktop app windows open.

## Test

### 1. Seed the sender with a database entry and its secrets

In the sender instance:

1. Navigate to the **Manage Secrets** page and add an `encryption-key` secret named `test-enc-key`.
2. Navigate to the **Manage Databases** (`sidebar-toggle-button`, then `sidebar-manage-databases`) page and click **Add database** (`add-database-button`).
3. Enter name `test-db` (`database-name-input`) and an arbitrary filesystem path (`database-path-input`), toggle **Encrypted** (`database-encrypted-switch`) on and link the `test-enc-key` encryption key (`select-encryption-button`, then `secret-select-button`, the `test-enc-key` row).

Expected:
- `test-db` is listed on the Databases page.

---

### 2. Start the share on the sender

1. From the sender's Databases page, click **Share database** (`share-database-button`, the `test-db` row).
2. Click the **Send** button (`share-database-send-button`) on the share dialog.

Expected:
- A 4-digit pairing code is shown.

Record the pairing code (`share-pairing-code`) as `<code>` for the next step.

---

### 3. Start the receive on the other instance

1. In the receiver instance, navigate to the **Manage Databases** (`sidebar-toggle-button`, then `sidebar-manage-databases`) page.
2. Click **Receive database** (`receive-database-button`), enter `<code>` (`receive-database-code-input`) and click **Start** (`receive-database-start-button`).

Expected:
- Inside the "Receive Database" modal, the form is populated with the database name (`test-db`), description and path, plus a checkbox for each linked secret (for example "Import S3 credentials (test-s3-key)").

---

### 4. Save the database on the receiver

1. Click **Save** (`receive-database-save-button`).

Expected:
- A success message indicates the database was imported.
- The receiver's Databases page contains `test-db`.
- The receiver's Manage Secrets page contains `test-enc-key`.

## Check

### 5. Verify the secret value came across

1. On the receiver's **Manage Secrets** page, click the **View secret** (eye) button (`view-secret-button`, the `test-enc-key` row) on the `test-enc-key` row.
2. Click **Reveal** (`reveal-secret-button`) to show the value.

Expected:
- The view dialog shows the same value that was seeded on the sender.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Click and type by the `data-id` given in brackets in each step.
- The **Manage Secrets** page has no `data-id` in the steps: reach it with `navigate` and `{"page": "secrets"}`.
- Two instances: start each test-hooks build with its own exports and its own `ZIGGY_TEST_PORT_FILE`, and send each command to the port of the instance the step names. Read the pairing code with `get-value` on `share-pairing-code`.
