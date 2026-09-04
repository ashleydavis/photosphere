# Mobile Manual Test: Create and Open a Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created on the device, closed and opened again, and that its contents survive a restart of the app.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

## Steps

### 1. Create a database

1. Open the menu and choose **New database**.
2. Give it a name you will recognise, such as `manual-test`.
3. Create it.

Expected: The app opens the new database and the gallery is empty.

---

### 2. Import a photo into it

1. Go to the **Import** page.
2. Choose a photo from the device.
3. Wait for the import to finish.

Expected:
- The photo appears in the gallery.
- No errors are shown.

---

### 3. Close and reopen it

1. Open the menu and choose **Open database**.
2. Pick a different database, or close the dialog and reopen `manual-test`.

Expected: The photo is still there.

---

### 4. Restart the app

1. Close the app completely.
2. Open it again.

Expected:
- The app reopens on the database that was last open, or offers it in the list.
- The photo is still there.

---

### 5. Look at the details

1. Open the database summary from the menu.

Expected:
- The number of assets matches what the gallery shows.
- The database's own details are shown without errors.
