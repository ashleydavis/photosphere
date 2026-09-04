# Mobile Manual Test: View an Asset and Edit its Details

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test opening a photo from the gallery, reading its details, editing them, and that the edit survives closing and reopening the database.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open with at least one photo in it.

## Steps

### 1. Open a photo

1. Go to the gallery.
2. Press and hold a thumbnail to open it.

Expected: The photo opens full screen and can be panned and zoomed.

---

### 2. Read its details

1. Open the info panel for the photo.

Expected:
- The file name, size and date are shown.
- The location and camera details are shown when the photo has them.

---

### 3. Edit the description

1. Type a description you will recognise.
2. Close the photo.

Expected: No error is shown, and the gallery is as it was.

---

### 4. Check the edit stuck

1. Close the database and open it again.
2. Open the same photo and its info panel.

Expected: The description you typed is still there.

This is the step that matters: an edit held only in memory looks identical until the database is reopened.

---

### 5. Move between photos

1. With a photo open, swipe to the next and previous ones.

Expected: Each loads without an error, and the info panel follows the photo being shown.
