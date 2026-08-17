# Mobile Manual Test: Point a Database at a Remote

Test setting a database's origin on the phone, so it syncs with a remote copy.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open on the phone, and a second copy reachable from it, either an S3 bucket or a database shared from the desktop.

## Steps

### 1. Set the origin

1. Open the database's details.
2. Set its origin to the remote copy.

Expected: The setting is accepted and shown.

---

### 2. Check it stuck

1. Close the app completely and reopen it.
2. Open the same database and its details.

Expected: The origin is still what you set.

---

### 3. Sync to the remote

1. Trigger a sync, or wait for the periodic one.

Expected:
- Photos on the phone appear in the remote copy.
- Photos added to the remote appear on the phone.

Check the remote from `apps/cli/`:

```bash
bun run start -- summary --db <remote>
```

---

### 4. A remote that is not reachable

1. Set the origin to something that does not exist.
2. Trigger a sync.

Expected: The app says the sync failed and why. It does not report success, and it does not hang with no explanation.
