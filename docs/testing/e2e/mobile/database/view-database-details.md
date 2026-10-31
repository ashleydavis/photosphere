# Mobile Manual Test: View a Database's Details

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the database summary: what the app says a database holds, and that it agrees with the gallery.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch.
- `test.png` goes into the device photo library for Test step 2 to import.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/test.png   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/test.png   # iOS
bun run ios:50   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts with a database open and a few photos in its gallery.

## Test

### 1. Open the summary

1. Open the side menu.
2. Choose the database summary.

Expected:
- The number of assets is shown and matches the gallery.
- The total size is shown.
- The database's own hash or identifier is shown.

### 2. Check it changes with the database

1. Import another photo: on the **Import** page, choose `test.png` from the device.
2. Open the summary again.

Expected: The asset count has gone up by one, and the size has grown.

## Check

### 3. Check it against the CLI

Share or replicate the database to your development machine, then from the repo root, with the CLI on the PATH:

```bash
psi summary --db <path to the copy>
```

Expected: The counts agree with what the phone showed. A phone that reports more assets than the database holds is reporting its own memory rather than the database.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Choosing a photo or video from the device needs the photos and videos permission. If the system asks for it, allow access to all photos.
- Check step 3 needs the database copied to the development machine, by sharing or replicating it from the phone, which is UI steps on the phone.
