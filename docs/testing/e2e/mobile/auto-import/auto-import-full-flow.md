# Mobile Manual Test: Automatic Import, End to End

Test the whole automatic photo backup flow on a phone: switching it on, the app making its own database, the photos already on the device being backed up, a photo taken while the app is running being backed up on its own, and the record of what was imported.

This is the flow the feature exists for, so it is worth running as one sitting rather than in pieces.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The device needs at least two photos in its photo library before you start, and you need to be able to take one more with the camera partway through.

If the app has been used before, remove its data first so the test starts with no database and no settings. On Android: **Settings > Apps > Photosphere > Storage > Clear storage**. On iOS: delete the app and let `bun run ios` reinstall it.

## Steps

### 1. Check where you are starting from

1. Open the app.
2. Open the menu and go to the gallery.

Expected: No database is open, and there is nothing in the gallery.

---

### 2. Switch automatic import on

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card.
3. Turn the toggle on.
4. When the system asks for permission to read your photos, allow it.

Expected:
- The toggle stays on.
- The app does not ask you to choose a database or a folder. There is nothing else to fill in.

---

### 3. The app makes its own database

1. Open the menu and choose **Open database**.

Expected:
- A database is listed that you did not create, holding the photos being backed up.
- Close the dialog without changing anything, or open that database to watch the rest of the test in the gallery.

---

### 4. The photos already on the device are backed up

1. Go to the gallery.
2. Wait. Photos already in the device library are worked through steadily rather than all at once, so give it a minute on a library of any size.

Expected:
- Photos from the device library appear in the gallery.
- They keep appearing until the library has been walked, and then it stops.
- The app stays usable throughout. Scrolling and navigating still work while the backup is running.

---

### 5. A photo taken now is backed up on its own

1. Leave the app open.
2. Switch to the camera app and take a photo.
3. Switch back to Photosphere and go to the gallery.

Expected:
- The new photo appears in the gallery without you importing it, and without reopening the database.
- It appears within a few seconds rather than only after a restart.

This is the part users notice: a photo taken a moment ago is already backed up.

---

### 6. See what was imported

1. Go to the **Import** page.

Expected:
- The photos that were backed up are listed, newest first.
- Each row is badged **automatic**.
- A count of what has been imported is shown while a backup is running.

---

### 7. The record survives a restart

1. Close the app completely and reopen it.
2. Open the database automatic import created.
3. Go to the **Import** page.

Expected:
- The list still shows what was imported, including from before the restart.
- The badges still say **automatic**.

This is the difference between a running total and a record: the app remembers what came in even though it was closed.

---

### 8. Switching it off stops it

1. Open the menu and choose **Configuration**.
2. Turn the **Automatic import** toggle off.
3. Take another photo with the camera.
4. Go back to the gallery.

Expected:
- The new photo does **not** appear.
- The photos already backed up are still there. Switching the feature off stops future backups and removes nothing.

---

### 9. Check the photos are really there

Share or replicate the database to your development machine, then from `apps/cli/`:

```bash
bun run start -- verify --db <path to the copy>
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery showed.

A photo that shows in the gallery but fails verification has been recorded without its content being stored, which is the failure this step is here to catch.
