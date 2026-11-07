# Mobile Manual Test: Export a Photo Out of the App

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test sending a photo from the database back out to the device, through the system share sheet on iOS or the system save dialog on Android.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:1` and `bun run ios:1` put the `1-asset` test database on the device as `test-1-asset` and open it on launch.
- `test.mp4` goes into the device photo library, because the database needs a video for Test step 3. After the app starts, go to the **Import** page and import it.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/multiple-files/test.mp4   # Android
bun run android:1   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/multiple-files/test.mp4   # iOS
bun run ios:1   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts, and after the import the open database holds a photo and a video.

## Test

### 1. Export a photo

1. Go to the gallery and open a photo.
2. Use the download or share action.
3. Choose somewhere to save it, such as Files or Downloads.

Expected:
- The system share sheet appears on iOS, and the system save dialog on Android.
- The photo is saved where you chose, and opens correctly in the system gallery or file browser.
- It is the full photo, not the thumbnail: the saved file is the same file as the database's stored original, `test/dbs/1-asset/asset/<asset id>`, which is 400 × 241 (the thumbnail is 200 × 121). The 5954 × 3590 the info panel shows is the size of the photo the fixture was made from, not of the copy the fixture stores.

### 2. Cancel an export

1. Open a photo and start the export again.
2. Dismiss the share sheet (iOS) or save dialog (Android) without choosing anything.

Expected:
- The app says the download was cancelled, or simply returns to the photo.
- No error is shown, and nothing is left behind on the device.

## Check

### 3. Export a video

1. Open a video in the gallery and export it.

Expected: The video is saved and plays back from the device.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- On Android the export opens the system save dialog (the code calls the system's create-document picker, not a share sheet). On iOS it opens the share sheet. Both are system screens, tapped like the app.
- Step 3: whether the video plays back is judged by the human.
