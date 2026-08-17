# Mobile Manual Test: LAN Share, Desktop to Phone

Test the desktop app sending a database entry and a secret to the phone on the same network. The phone is the target.

## Prerequisites

The phone running the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The desktop app running on a machine on the same local network:

```bash
bun run dev
```

The phone must be on Wi-Fi, not mobile data.

## Steps

### 1. Receive a secret from the desktop

1. On the phone, go to **Secrets** and start receiving. Note the pairing code.
2. On the desktop, choose a secret and share it, entering that code.

Expected:
- The phone receives it within a few seconds.
- The secret is listed on the phone with the value it had on the desktop.

---

### 2. Receive a database entry from the desktop

1. On the phone, start receiving a database entry and note the code.
2. On the desktop, share a database entry with that code.

Expected:
- The entry arrives and is listed on the phone.
- Opening it loads the assets, fetching them from wherever the entry points, which may be an S3 bucket rather than the desktop itself.

---

### 3. Receive an encrypted database and its key

1. Share the encryption key from the desktop to the phone.
2. Share the encrypted database's entry.
3. Open it on the phone.

Expected: The photos are readable, as in [open-encrypted-database](../database/open-encrypted-database.md). This is the pair a user actually needs: an entry without its key is not usable.

---

### 4. Cancel on the phone

1. Start receiving on the phone and cancel it before the desktop sends.

Expected: The phone stops waiting and the desktop's send eventually reports that nothing received it. Neither claims success.

---

### 5. Nothing sends

1. Start receiving on the phone and leave it.

Expected: It gives up after its own timeout and says so, rather than waiting for ever.
