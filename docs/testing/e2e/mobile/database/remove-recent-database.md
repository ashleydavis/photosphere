# Mobile Manual Test: Remove a Database from the List

Test removing a database entry from the app, and that a database whose files have gone is handled rather than crashing the app.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

At least two databases listed in the app.

## Steps

### 1. Remove one from the list

1. Open the database list.
2. Remove a database you are not using.

Expected:
- It disappears from the list.
- The database that is open is unaffected.

---

### 2. Check the removal stuck

1. Close the app completely and reopen it.

Expected: The removed database is still absent from the list.

---

### 3. Removing an entry does not delete the photos

1. Add the same database back, by receiving it again or by opening it by name.

Expected: Its photos are all still there. Removing an entry forgets where a database was, it does not destroy it.

---

### 4. A database that has gone

1. Add an entry for a database that does not exist, or remove the storage a listed database points at.
2. Open the list and try to open it.

Expected:
- The app says it cannot open that database.
- It does not crash, and does not sit on a loading screen with no explanation.
- The other databases still open normally afterwards.
