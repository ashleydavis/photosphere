# Mobile Manual Test: LAN Share, Phone to Phone

Test one phone sending a database entry and a secret to another phone on the same network. This is the only one of the three LAN tests where a phone is the sender as well as the target.

## Prerequisites

Two devices, both running the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

Both must be on the same local network, on Wi-Fi rather than mobile data. This does not work over the internet.

Run it at least once with both phones on the same platform, and once with one Android and one iOS, since the two implementations only meet here.

## Steps

### 1. Send a secret from one phone to the other

1. On the receiving phone, go to **Secrets** and start receiving. Note the pairing code it shows.
2. On the sending phone, choose a secret and share it, entering that code.

Expected:
- The receiving phone finds the sender within a few seconds.
- The secret arrives with the same name and value.
- Neither phone is left showing a progress spinner after it completes.

---

### 2. Send a database entry the other way

1. On the phone that sent the secret, start receiving a database entry and note its code.
2. On the other phone, share a database entry using that code.

Expected:
- The entry arrives and is listed.
- Opening it reaches the same storage, so the photos are the same on both phones.

---

### 3. Both phones on mobile data

1. Turn Wi-Fi off on both phones.
2. Try to share.

Expected: The devices do not find each other and both say so after their own timeout. Neither claims success.

---

### 4. The wrong code

1. Start receiving on one phone and note its code.
2. Send from the other using a different code.

Expected: Nothing is transferred, and the receiving phone says a device was found using a different code rather than appearing to hang.

---

### 5. Cancel from each side

1. Start a share and cancel it on the sender.
2. Start another and cancel it on the receiver.

Expected: Both end cleanly, and a further share works straight away without either app being restarted.
