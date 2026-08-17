# Mobile Manual Test: Replicate a Database

Test copying a database from the phone to another location, and that the copy is complete and verifiable.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open on the phone with a few photos in it, and somewhere to replicate to that the phone can reach: an S3 bucket, or a database shared from the desktop.

## Steps

### 1. Replicate it

1. Start a replication from the phone to the destination.
2. Wait for it to finish.

Expected:
- Progress is shown while it runs.
- It reports completion rather than stopping silently.

---

### 2. Check the copy

From `apps/cli/`:

```bash
bun run start -- verify --db <the destination>
bun run start -- compare --db <the source, if reachable> --dest <the destination>
```

Expected:
- Verification passes with no failures.
- The comparison reports the two as the same.

---

### 3. Replicate again with nothing changed

1. Run the same replication a second time.

Expected: It completes quickly and copies little or nothing. A replication that copies everything again every time is worth noting.

---

### 4. Replicate after a change

1. Import one more photo on the phone.
2. Replicate again.

Expected: Only the new photo is copied, and the destination then holds it.

---

### 5. Interrupt one

1. Start a replication of a larger database and put the phone in flight mode partway.

Expected:
- The app says the replication failed rather than reporting success.
- Running it again once the network is back completes it, rather than starting from nothing.
