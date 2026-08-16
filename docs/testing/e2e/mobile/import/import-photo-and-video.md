# Mobile Manual Test: Import a Photo and a Video by Hand

Test importing media the user picks, which is the path automatic import does not cover.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

A database open, as in [create-and-open-database](../database/create-and-open-database.md). The device needs at least one photo and one video.

## Steps

### 1. Import a photo

1. Go to the **Import** page.
2. Choose a photo from the device.

Expected:
- The import completes and the photo appears in the gallery.
- The Import page lists it, badged **manual**.

---

### 2. Import a video

1. Go to the **Import** page.
2. Choose a video from the device.

Expected:
- The import completes and the video appears in the gallery with a thumbnail.
- Opening it plays it back.

---

### 3. Import the same photo again

1. Import the photo from step 1 a second time.

Expected:
- It is reported as already present rather than added twice.
- The gallery still shows one copy.

---

### 4. Check the import record

1. Stay on the **Import** page.

Expected:
- Both imports are listed, newest first, badged **manual**.
- If automatic import has also run on this database, its rows are in the same list badged **automatic**.
