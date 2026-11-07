# Mobile Manual Test: Automatic Import Without the Photo Permission

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that refusing the photo permission is said out loud rather than leaving the feature switched on and doing nothing.

A user who taps "Don't allow" and then sees the toggle sitting on has been told the backup is running when it cannot run at all.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- After the reset, the photo permission must not be granted yet. On Android: **Settings > Apps > Photosphere > Permissions > Photos and videos > Don't allow**. On iOS: **Settings > Photosphere > Photos > None**.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.

## Test

### 1. Switch automatic import on and refuse the permission

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card.
3. Turn the toggle on.
4. When the system asks for permission to read your photos, refuse it.

Expected:
- The toggle switches itself back off.
- A message says the app needs permission to read your photos.
- No database is created: **Open database** lists nothing new.

### 2. Grant the permission and try again

1. Grant the photo permission in the system settings for the app.
2. Return to Photosphere and turn the **Automatic import** toggle on again.

Expected:
- The toggle stays on this time.
- The app creates its database and starts backing up, as in [the new remote test](auto-import-new-remote.md).

## Check

### 3. Take the permission away while it is running

1. Leave automatic import on.
2. In the system settings for the app, revoke the photo permission.
3. Return to Photosphere.

Expected:
- The app does not crash, and does not sit reporting progress it cannot be making.
- Automatic import stops, and the app says why.

Note what actually happens here if it differs: the app may be restarted by the operating system when a permission is revoked, which is the system's doing rather than the app's.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 1: the system photos and videos permission appears; tap **Don't allow**. If a notifications permission appears, allow it.
- Steps 2 and 3 grant and revoke the permission in the system settings app (**Settings > Apps > Photosphere > Permissions > Photos and videos**), which is driven with taps like the app itself.
