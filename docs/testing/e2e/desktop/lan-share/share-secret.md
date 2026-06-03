# Desktop Manual Test: Share a Secret Over LAN

Test that one Photosphere desktop instance can share a secret with another over
the local network.

## Prerequisites

- Two Photosphere desktop instances available: either on two machines on the
  same LAN, or two separate copies on the same machine launched against
  different config/vault directories.
- The fastest way to launch a second isolated instance on the same machine is
  to start `bun run dev` from a second checkout / worktree, or to point the
  app at alternate config and vault directories via the relevant
  Photosphere environment variables before launching.

The walkthrough below describes the "two machines / two app instances" form.
Substitute terminal A for the sender and terminal B for the receiver.

## Steps

### 1. Seed the sender with a secret to share

In the sender instance:

1. Navigate to the **Manage Secrets** page.
2. Click **Add secret**, type `test-secret`, and confirm.

Expected:
- `test-secret` appears in the Secrets list.

---

### 2. Start the share on the sender

1. In the sender, navigate to the **Manage Secrets** page.
2. Click **Share secret**.
3. Click the **Send** button on the share dialog.

Expected:
- A 4-digit pairing code is shown.

Record that code as `<code>` for the next step.

---

### 3. Start the receive on the other instance

1. In the receiver instance, navigate to the **Manage Secrets** page.
2. Click **Receive secret**.
3. Type the 4-digit pairing code `<code>` and click **Start**.

Expected:
- The receiver shows a "Secret review" step.

---

### 4. Save the secret on the receiver

1. Click **Save**.

Expected:
- A success message indicates the secret was saved.
- The receiver's Manage Secrets page lists `test-secret`.
- The receiver's vault directory contains a `test-secret.json` file with the same value as the sender's copy.
