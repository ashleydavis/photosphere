# Mobile Manual Test: Import a Photo and a Video by Hand

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test importing media the user picks, which is the path automatic import does not cover.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:0` and `bun run ios:0` put the empty `no-assets` test database on the device as `test-no-assets` and open it on launch.
- `test.jpg` and `test.mp4` go into the device photo library, for the test to import.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/test.jpg test/multiple-files/test.mp4   # Android
bun run android:0   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/test.jpg test/multiple-files/test.mp4   # iOS
bun run ios:0   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts with an empty database open.

## Test

### 1. Import a photo

1. Go to the **Import** page.
2. Choose a photo from the device.

Expected:
- The import completes and the photo appears in the gallery.
- The Import page lists it, badged **manual**.

### 2. Import a video

1. Go to the **Import** page.
2. Choose a video from the device.

Expected:
- The import completes and the video appears in the gallery with a thumbnail.
- Opening it plays it back.

### 3. Import the same photo again

1. Import the photo from step 1 a second time.

Expected:
- It is reported as already present rather than added twice.
- The gallery still shows one copy.

## Check

### 4. Check the import record

1. Stay on the **Import** page.

Expected:
- Both imports are listed, newest first, badged **manual**.
- If automatic import has also run on this database, its rows are in the same list badged **automatic**.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Choosing a photo or video from the device needs the photos and videos permission. If the system asks for it, allow access to all photos.
- Step 2: whether the video plays back is judged by the human.
