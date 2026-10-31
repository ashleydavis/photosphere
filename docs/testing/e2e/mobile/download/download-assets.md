# Mobile Manual Test: Download Assets to the Device

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test pulling photos out of a database onto the phone, one at a time and several at once.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch.
- `test.mp4` goes into the device photo library, because the database needs a video for Test step 3. After the app starts, go to the **Import** page and import it.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/multiple-files/test.mp4   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/multiple-files/test.mp4   # iOS
bun run ios:50   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts, and after the import the open database holds several photos and a video.

## Test

### 1. Download one photo

1. Open a photo in the gallery.
2. Download it to the device.

Expected:
- It is saved where you chose.
- It appears in the device's own gallery app.
- It is the full photo, not the thumbnail: the saved file is the same file as the database's stored original, `test/dbs/50-assets/asset/<asset id>`. The fixture stores a reduced copy of each photo (for example 400 × 600 where the info panel shows 2555 × 3832), so the size the info panel shows is not the size of the stored file.

### 2. Download several at once

1. Select several photos in the gallery.
2. Download them together.
3. Download the same photos again, into the same folder.

Expected:
- Progress is shown while it runs.
- Every photo you selected arrives, not just the first.
- The names do not collide: the second download lands a second copy of each photo beside the first, rather than overwriting it. (No two photos in the `50-assets` fixture share a name, so a second download of the same photos is what gives two files the same name.)

### 3. Download a video

1. Select a video and download it.

Expected: It saves and plays back from the device.

## Check

### 4. Cancel partway

1. Start a download of several large photos and cancel it.

Expected:
- The app stops and says so.
- What had already been saved is still there, and the app is usable straight away.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- On Android, saving one photo opens the system save dialog and saving several opens the system folder picker. On iOS it opens the share sheet. These are system screens, tapped like the app. Checking the download in the system gallery app is done with a screenshot there.
- Step 3: whether the video plays back is judged by the human.
- Step 4 has to cancel partway, so take a screenshot straight after starting and tap cancel as soon as progress shows.
