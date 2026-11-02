# Mobile Manual Test: Create and Open a Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created on the device, closed and opened again, and that its contents survive a restart of the app.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.

## Test

### 1. Create a database

1. Open the menu and choose **New database**.
2. Give it a name you will recognise, such as `manual-test`.
3. Create it.

Expected: The app opens the new database and the gallery is empty.

### 2. Import a photo into it

1. Go to the **Import** page.
2. Choose a photo from the device.
3. Wait for the import to finish.

Expected:
- The photo appears in the gallery.
- No errors are shown.

### 3. Close and reopen it

1. Open the menu and choose **Open database**.
2. Pick a different database, or close the dialog and reopen `manual-test`.

Expected: The photo is still there.

### 4. Restart the app

1. Close the app completely.
2. Open it again.

Expected:
- The app reopens on the database that was last open, or offers it in the list.
- The photo is still there.

## Check

### 5. Look at the details

1. Open the database summary from the menu.

Expected:
- The number of assets matches what the gallery shows.
- The database's own details are shown without errors.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Choosing a photo or video from the device needs the photos and videos permission. If the system asks for it, allow access to all photos.
- To close the app completely on Android, use the system's recent apps screen or `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
