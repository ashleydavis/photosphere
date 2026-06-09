# Desktop Manual Test: Share a Database Entry Over LAN

Test that the desktop app can share a database entry (with its linked secrets)
from one instance to another.

## Prerequisites

You need two desktop instances that can see each other over the local network.
The simplest way is to run two isolated copies on the same machine, each
pointed at its own config and vault directories so they do not share state or
the OS keychain.

Start the **sender** in terminal A:

```sh
PHOTOSPHERE_CONFIG_DIR=/tmp/ps-sender/config \
PHOTOSPHERE_VAULT_TYPE=plaintext \
PHOTOSPHERE_VAULT_DIR=/tmp/ps-sender/vault \
bun run dev
```

Start the **receiver** in terminal B:

```sh
PHOTOSPHERE_CONFIG_DIR=/tmp/ps-receiver/config \
PHOTOSPHERE_VAULT_TYPE=plaintext \
PHOTOSPHERE_VAULT_DIR=/tmp/ps-receiver/vault \
bun run dev
```

Notes:
- `PHOTOSPHERE_CONFIG_DIR` isolates each instance's database/secret config.
- `PHOTOSPHERE_VAULT_DIR` isolates each instance's vault files.
- `PHOTOSPHERE_VAULT_TYPE=plaintext` stores secrets as JSON files under the
  vault directory instead of the shared OS keychain, so the two instances stay
  independent (and you can inspect the vault files directly).

Both instances run on the same machine and discover each other over local
loopback. (Two separate machines on the same LAN also works; run one command
per machine.)

The sender starts empty. Step 1 below seeds it with a database entry and its
linked secret(s).

## Steps

### 1. Seed the sender with a database entry and its secrets

In the sender instance:

1. Navigate to the **Manage Secrets** page and add an `encryption-key` secret named `test-enc-key`.
2. Navigate to the **Manage Databases** page and click **Add database**.
3. Enter name `test-db` and an arbitrary filesystem path, toggle **Encrypted** on, and link the `test-enc-key` encryption key.

Expected:
- `test-db` is listed on the Databases page.

---

### 2. Start the share on the sender

1. From the sender's Databases page, click **Share database**.
2. Click the **Send** button on the share dialog.

Expected:
- A 4-digit pairing code is shown.

Record the pairing code as `<code>` for the next step.

---

### 3. Start the receive on the other instance

1. In the receiver instance, navigate to the **Manage Databases** page.
2. Click **Receive database**, enter `<code>`, and click **Start**.

Expected:
- Inside the "Receive Database" modal, the form is populated with the database name (`test-db`), description, and path, plus a checkbox for each linked secret (for example "Import S3 credentials (test-s3-key)").

---

### 4. Save the database on the receiver

1. Click **Save**.

Expected:
- A success message indicates the database was imported.
- The receiver's Databases page contains `test-db`.
- The receiver's Manage Secrets page contains `test-enc-key`.

---

### 5. Verify the secret value came across

1. On the receiver's **Manage Secrets** page, click the **View secret** (eye) button on the `test-enc-key` row.

Expected:
- The view dialog shows the same value that was seeded on the sender.
