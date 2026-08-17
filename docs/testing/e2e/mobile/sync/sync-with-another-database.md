# Mobile Manual Test: Sync With Another Copy of a Database

Test that changes made on the phone reach another copy of the database, and that changes made there reach the phone.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open on the phone with its origin set to a copy you can reach from your development machine, as in [edit-database-origin](../database/edit-database-origin.md).

## Steps

### 1. Add a photo on the phone

1. Import a photo you will recognise.
2. Let the phone sync.

Check the other copy from `apps/cli/`:

```bash
bun run start -- list --db <the other copy>
```

Expected: The photo is listed there.

---

### 2. Add a photo on the other side

From `apps/cli/`:

```bash
bun run start -- add ../../test/test.jpg --db <the other copy>
```

Then let the phone sync and open the gallery.

Expected: The photo appears on the phone without the database being closed and reopened.

---

### 3. Edit on one side

1. Edit a photo's description on the phone.
2. Let it sync, then read that asset from the other copy.

Expected: The description is there.

---

### 4. Delete on one side

1. Delete a photo on the phone.
2. Let it sync.

Expected: It goes from the other copy too, and does not come back on the next sync.

---

### 5. Both sides changed at once

1. Put the phone in flight mode.
2. Add a photo on the phone, and a different one on the other copy.
3. Bring the phone back online and let it sync.

Expected: Both photos end up in both copies. Neither side wins by discarding the other's work.
