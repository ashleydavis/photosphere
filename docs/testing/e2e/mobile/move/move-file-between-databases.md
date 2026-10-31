# Mobile Manual Test: Move a Photo Between Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test moving a photo from one database to another, and that it arrives whole and leaves the first.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:1` and `bun run ios:1` put the `1-asset` test database on the device as `test-1-asset` and open it on launch. That is the first database, and its one photo is the photo to move.
- The test needs a second database. After the app starts, open the menu, choose **New database** and name it `manual-test-2`.

```bash
bun run android:reset   # Android
bun run android:1   # Android
bun run ios:reset   # iOS
bun run ios:1   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- Two databases are listed on the phone, the first with a photo you will recognise.

## Test

### 1. Move a photo

1. Open the first database and find the photo.
2. Move it to the second database.

Expected:
- The app says the move completed.
- The photo is gone from the first database's gallery.

## Check

### 2. Check it arrived

1. Open the second database.

Expected:
- The photo is there.
- Opening it full screen shows the whole photo, not a broken thumbnail. A move that copies the record without the content looks fine in the gallery and fails here.

### 3. Check it left

1. Open the first database again.

Expected: The photo is still gone, after the database has been closed and reopened rather than only in the view that was on screen.

### 4. Check both databases are sound

Share or replicate both to your development machine, then from the repo root, with the CLI on the PATH:

```bash
psi verify --db <the first>
psi verify --db <the second>
```

Expected: Both verify with no failures. A move that leaves the source database referring to content it no longer has is the failure this step catches.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Selecting the photo on a phone is a press and hold: `input swipe X Y X Y 800`, with the same start and end point.
- Check step 4 needs both databases copied to the development machine, by sharing or replicating them from the phone, which is UI steps on the phone.
