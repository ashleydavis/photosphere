# Mobile Manual Test: Deleting the Photo After it is Backed Up

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test freeing up space: once a photo is confirmed in the database, the copy in the device photo library can be deleted from the **Free up space on this device** part of the **Automatic import** card.

This test destroys photos on the device, on purpose. Run it on a test device or with photos you are willing to lose, and never on a phone holding anything you care about.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- After the app starts, get automatic import working: open the menu, choose **Configuration**, turn the **Automatic import** toggle on and allow the photo permission. Wait until the photos already in the library have appeared in the gallery and no more arrive.
- The two throwaway photos are put in the device library during Test steps 2 and 3.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- Automatic import is on, and the photos already in the library are in the gallery.

## Test

### 1. Find the photos the database already holds

1. Open the menu and choose **Configuration**.
2. In the **Automatic import** card, under **Free up space on this device**, press **Find photos already in my database**.

Expected:
- A message says how many of the photos on this device are in the database and can be deleted.
- The button changes to **Delete N photo(s) from this device**. Nothing is deleted yet on its own.

### 2. Back up a photo and let it be deleted

1. Take a photo, or put the first throwaway photo in the device library and wait for it to be backed up:

```bash
bun run android:add-fixtures -- test/multiple-files/test-1.jpeg   # Android
bun run ios:add-fixtures -- test/multiple-files/test-1.jpeg   # iOS
```

2. In **Configuration**, press **Find photos already in my database**, then **Delete N photo(s) from this device**.
3. When the system asks whether to delete the photos from the library, allow it.

Expected:
- The photo disappears from the device photo library, checked in the system gallery app.
- The photo is still in the Photosphere gallery. It was moved, not lost.

### 3. Refuse the deletion

1. Put the second throwaway photo in the device library and wait for it to be backed up:

```bash
bun run android:add-fixtures -- test/multiple-files/test-2.png   # Android
bun run ios:add-fixtures -- test/multiple-files/test-2.png   # iOS
```

2. In **Configuration**, press **Find photos already in my database**, then **Delete N photo(s) from this device**.
3. When the system asks whether to delete it, refuse.

Expected:
- The photo stays in the device photo library.
- The photo is in the Photosphere gallery as well. Refusing the deletion does not undo the backup.
- The app does not ask again in a loop for the same photo while it keeps running.

### 4. A photo that failed to import is never deleted

1. Turn automatic import off.
2. Put a file in the device photo library that is not a real image: copy any small file and rename it to end in `.jpg`.
3. Turn automatic import back on and wait for it to be walked past.
4. Press **Find photos already in my database**, and if it offers to delete, press **Delete N photo(s) from this device** and allow it.

Expected:
- The file is **not** deleted from the device library.
- The gallery does not show a broken entry for it.

This is the case that matters most: deletion has to follow the photo actually being in the database, not the import merely reporting it tried.

## Check

### 5. Check what survived

Share or replicate the database to your development machine, then from the repo root, with the CLI on the PATH:

```bash
psi verify --db <path to the copy>
```

Expected:
- Verification completes without errors.
- Every photo that was deleted from the device is present and intact in the database.

A photo deleted from the device and missing here is the one unrecoverable failure this feature can have, which is why this step is not optional.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Turning automatic import on in Prep brings up the system photos and videos permission: allow access to all photos, not a selection. If a notifications permission follows, allow it.
- Step 2 uses the `add-fixtures` command rather than the camera. The system's request to delete the photo is a system dialog: tap **Allow** in step 2 and **Deny** (or the refusing button) in step 3.
- Checking the photo has gone from, or stayed in, the device library means opening the system gallery app and taking a screenshot there.
- Step 4 needs a file that is not a real image in the device library. `android:add-fixtures` fails when MediaStore does not list the file as a photo or video, so it may refuse this file. That has not been tried.
