# Desktop Manual Test: Share a Secret Over LAN

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that one Photosphere desktop instance can share a secret with another over
the local network.

## Prep

You need two desktop instances that can see each other over the local network.
The simplest way is to run two isolated copies on the same machine, each
pointed at its own folders so they do not share state or the OS keychain.

The app is started with the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`, from the repo root. The commands below use `linux`.

Open two terminals at the repo root: terminal A for the **sender** and terminal B for the **receiver**.

In either terminal, clean up any previous run of this test:

```bash
rm -rf /tmp/psi-desktop-share-secret
```

Start the **sender** in terminal A:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-share-secret/sender/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-share-secret/sender/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-share-secret/sender/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-share-secret/sender/logs
export XDG_DATA_HOME=/tmp/psi-desktop-share-secret/sender/data
bun run linux
```

Start the **receiver** in terminal B:

```bash
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-desktop-share-secret/receiver/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-desktop-share-secret/receiver/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR=/tmp/psi-desktop-share-secret/receiver/cache
export PHOTOSPHERE_LOG_DIR=/tmp/psi-desktop-share-secret/receiver/logs
export XDG_DATA_HOME=/tmp/psi-desktop-share-secret/receiver/data
bun run linux
```

Each block keeps that instance's settings, secrets, cache, logs and the app's own data (its web view data and its one-copy-at-a-time lock) in its own folder, away from the other instance, from other tests and from a normal install. Two copies on one machine need separate data folders, otherwise the second copy is refused by the one-copy lock.

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA=/tmp/psi-desktop-share-secret/sender/data` (and `.../receiver/data` for the receiver) in its place. On macOS the app's data cannot be moved this way, so two copies cannot run on one machine: quit any other copy of Photosphere and run the sender and receiver on two machines.

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

Expected:
- The cleanup prints nothing.
- Both desktop app windows open.

## Test

### 1. Seed the sender with a secret to share

In the sender instance:

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**.
3. In the dialog, type `test-secret` into the name field.
4. Set the **Type** to `api-key`.
5. Type `test-value` into the **API Key** field.
6. Click **Save**.

Expected:
- `test-secret` appears in the Secrets list.

---

### 2. Start the share on the sender

1. On the sender's **Manage Secrets** page, click **Share secret**.
2. Click the **Send** button on the share dialog.

Expected:
- A 4-digit pairing code is shown.

Record that code as `<code>` for the next step.

---

### 3. Start the receive on the other instance

1. In the receiver instance, navigate to the **Manage Secrets** page.
2. Click **Receive secret**.
3. Type the 4-digit pairing code `<code>` and click **Start**.

Expected:
- After a brief "Waiting for sender..." message, the receiver shows the incoming secret's `Type: api-key` and a **Save as (name)** field.

---

### 4. Save the secret on the receiver

1. Type `test-secret` into the **Save as (name)** field.
2. Click **Save**.

Expected:
- A success message ("Secret imported successfully!") is shown.
- The receiver's Manage Secrets page lists `test-secret`.

## Check

### 5. Verify the value came across

1. On the receiver, click the **View secret** (eye) button on the `test-secret` row.
2. Click the **Reveal** button to show the value.

Expected:
- The revealed value is `test-value` (matching the value seeded on the sender).
