# Desktop Manual Test: Share a Secret Over LAN

Test that one Photosphere desktop instance can share a secret with another over
the local network.

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

## Steps

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

---

### 5. Verify the value came across

1. On the receiver, click the **View secret** (eye) button on the `test-secret` row.
2. Click the **Reveal** button to show the value.

Expected:
- The revealed value is `test-value` (matching the value seeded on the sender).
