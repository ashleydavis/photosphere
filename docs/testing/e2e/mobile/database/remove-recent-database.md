# Mobile Manual Test: Remove a Database from the List

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test removing a database entry from the app, and that a database whose files have gone is handled rather than crashing the app.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `bun run android:1` and `bun run ios:1` put the `1-asset` test database on the device as `test-1-asset` and open it on launch.
- The test needs two databases listed. After the app starts, open the menu, choose **New database** and name it `manual-test-2`.

```bash
bun run android:reset   # Android
bun run android:1   # Android
bun run ios:reset   # iOS
bun run ios:1   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The app starts, and after **New database** two databases are listed, one of them holding a photo.

## Test

### 1. Remove one from the list

1. Open the database list.
2. Remove a database you are not using.

Expected:
- It disappears from the list.
- The database that is open is unaffected.

### 2. Check the removal stuck

1. Close the app completely and reopen it.

Expected: The removed database is still absent from the list.

### 3. Removing an entry does not delete the photos

1. Add the same database back, by receiving it again or by opening it by name.

Expected: Its photos are all still there. Removing an entry forgets where a database was, it does not destroy it.

## Check

### 4. A database that has gone

1. Add an entry for a database that does not exist, or remove the storage a listed database points at.
2. Open the list and try to open it.

Expected:
- The app says it cannot open that database.
- It does not crash, and does not sit on a loading screen with no explanation.
- The other databases still open normally afterwards.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- To close the app completely on Android, use the system's recent apps screen or `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
