# Mobile Manual Test: Open a Database With Many Photos

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the app against a database large enough to show whether the gallery scrolls, loads and stays usable on a phone.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- A database with at least fifty photos in it: the `50-assets` test database, which holds 60.
- `bun run android:50` and `bun run ios:50` put it on the device as `test-50-assets` and open it on launch.
- `test/dbs/50-assets` is what Check step 5 runs `psi summary` against.

```bash
bun run android:reset   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:50   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts with `test-50-assets` open.

## Test

### 1. Open it

1. Open the database on the phone.

Expected:
- The gallery appears without the app freezing.
- Thumbnails fill in as they load rather than the screen staying blank until every one is ready.

### 2. Scroll it

1. Scroll from the top to the bottom and back.

Expected:
- Scrolling stays smooth.
- Thumbnails load as you go and do not disappear again once loaded.
- No photo shows as broken.

### 3. Open photos from the middle and the end

1. Open a photo from partway down, and one from the very end.

Expected: Both load full screen.

### 4. Leave and come back

1. Send the app to the background, use another app, and come back.

Expected: The gallery is where you left it and is still usable, rather than reloading from the top or showing an empty screen.

## Check

### 5. Check nothing was lost

1. Open the database summary.

From the repo root, with the CLI on the PATH:

```bash
psi summary --db test/dbs/50-assets
```

Expected: The count matches what the CLI reports for the same database with `psi summary`.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Scroll with `input swipe`. Whether scrolling is smooth cannot be judged from screenshots, so the human judges step 2's smoothness while the agent checks for broken or missing thumbnails.
- Step 4: send the app to the background with `adb -s <serial> shell input keyevent KEYCODE_HOME`, open another app, then bring Photosphere back from the recent apps screen.
