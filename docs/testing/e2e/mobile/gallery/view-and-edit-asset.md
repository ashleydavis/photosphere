# Mobile Manual Test: View an Asset and Edit its Details

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test opening a photo from the gallery, reading its details, editing them, and that the edit survives closing and reopening the database.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch. Test step 5 needs more than one photo.

```bash
bun run android:reset   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:50   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts with a database open and several photos in its gallery.

## Test

### 1. Open a photo

1. Go to the gallery.
2. Tap a thumbnail to open it. A press and hold selects it instead.

Expected: The photo opens full screen and can be panned and zoomed.

### 2. Read its details

1. Open the info panel for the photo.

Expected:
- The file name, size and date are shown.
- The location and camera details are shown when the photo has them.

### 3. Edit the description

1. Type a description you will recognise.
2. Close the photo.

Expected: No error is shown, and the gallery is as it was.

## Check

### 4. Check the edit stuck

1. Close the database and open it again.
2. Open the same photo and its info panel.

Expected: The description you typed is still there.

This is the step that matters: an edit held only in memory looks identical until the database is reopened.

### 5. Move between photos

1. With a photo open, swipe to the next and previous ones.

Expected: Each loads without an error, and the info panel follows the photo being shown.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 1's tap is `input tap X Y`. Pan with `input swipe`. A pinch to zoom needs two fingers, which `input` cannot do, so the human checks zoom.
- Step 3 types the description with `input text`. Step 5 swipes with `input swipe`.
