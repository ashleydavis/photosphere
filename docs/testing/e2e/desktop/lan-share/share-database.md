# Desktop Manual Test: Share a Database Entry Over LAN

Test that the desktop app can share a database entry (with its linked secrets)
from one instance to another.

## Prerequisites

- Two Photosphere desktop instances available (see
  `desktop/lan-share/share-secret.md` for one way to launch a second isolated
  instance on the same machine).
- The sender must have a registered database entry with at least one linked
  secret (for example an S3 credential).

## Steps

### 1. Seed the sender with a database entry and its secrets

In the sender instance:

1. Navigate to the **Manage Secrets** page and add an `s3-credentials` secret named `test-s3-key` with `region`, `accessKeyId`, and `secretAccessKey` set to test values.
2. (Optional) Add an `encryption-key` secret named `test-enc-key`.
3. Navigate to the **Manage Databases** page and click **Add database**.
4. Enter name `test-db`, an arbitrary path, and link the S3 credential (and the encryption key, if you created one).

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
- The receiver shows a "Database review" step listing `test-db` and its linked secrets.

---

### 4. Save the database on the receiver

1. Click **Save**.

Expected:
- A success message indicates the database was imported.
- The receiver's Databases page contains `test-db`.
- The receiver's Manage Secrets page contains `test-s3-key` (and `test-enc-key`, if seeded).
- The corresponding vault files exist on the receiver.
