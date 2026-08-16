# Mobile Manual Test: Receive a Database and a Secret over the LAN

Test that the phone can receive a database entry and a secret sent from the desktop app or the CLI on the same network.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The phone and the sending machine must be on the same local network. This does not work over the internet, and a phone on mobile data will not find the sender.

The sender is either the desktop app or the CLI, run from `apps/cli/`.

## Steps

### 1. Receive a secret

1. On the phone, go to **Secrets** and start receiving a secret. Note the pairing code it shows.
2. On the development machine, send a secret with that code:

   ```bash
   bun run start -- secrets send --name <secret name> --code <pairing code>
   ```

Expected:
- The phone finds the sender and receives the secret within a few seconds.
- The secret is listed on the phone with the value it had on the sender.

---

### 2. Receive a database entry

1. On the phone, start receiving a database entry and note the pairing code.
2. On the development machine:

   ```bash
   bun run start -- dbs send --name <database name> --code <pairing code>
   ```

Expected:
- The phone receives the entry and lists the database.
- Opening it loads the assets, fetching them from wherever the entry points.

---

### 3. Cancel a receive

1. Start receiving on the phone and note the code.
2. Cancel it on the phone without sending anything.

Expected: The dialog closes and the phone is no longer waiting. Starting another receive works normally.

---

### 4. Use the wrong code

1. Start receiving on the phone and note the code.
2. Send from the machine using a different code.

Expected: The transfer does not complete, and the phone says a device was found using a different code rather than appearing to hang. The wait may run its full length before it says so.
