# Mobile Manual Test: Add and View a Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a secret can be added to the app's vault on the device, viewed, renamed and removed.

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

### 1. Add a secret

1. Open the menu and go to **Secrets**.
2. Add a new secret of type API key, named `manual-test-key`, with any value.
3. Save it.

Expected: The secret is listed by name.

### 2. View it

1. Open `manual-test-key`.

Expected:
- The value is shown, or revealed on request.
- The value matches what you entered.

### 3. Rename it

1. Rename it to `manual-test-key-renamed`.

Expected: The list shows the new name and no duplicate is left behind.

### 4. Add a duplicate name

1. Add another secret using the name `manual-test-key-renamed`.

Expected: The app refuses it and says why, rather than saving a second secret with the same name or silently doing nothing.

### 5. Remove it

1. Delete `manual-test-key-renamed`.

Expected: It is gone from the list, and still gone after the app is closed and reopened.

## Check

### 6. Check it survives a restart

1. Add a secret, close the app completely, and reopen it.

Expected: The secret is still listed with its value intact, which is what proves it was written to the device's own secure storage rather than held in memory.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Names and values are typed with `input text`.
- To close the app completely on Android, use the system's recent apps screen or `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
