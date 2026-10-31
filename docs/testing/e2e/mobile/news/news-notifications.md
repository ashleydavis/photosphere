# Mobile Manual Test: News Notifications

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that news published for the app reaches the phone, is readable, and does not keep announcing itself once read.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- The desktop test uses a local feed through `PHOTOSPHERE_NEWS_URL` (see `docs/testing/e2e/desktop/news/setup-news-feed.sh`). On the phone, run against the published feed unless you can point the build at your own.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.

## Test

### 1. See the news

1. Open the app with a network connection.

Expected: Unread news is indicated, rather than arriving silently.

### 2. Read it

1. Open the news.

Expected:
- The entries are readable and fit the phone screen, with no text cut off at the edges.
- Links open in the device browser rather than inside the app.

### 3. It stays read

1. Close the app completely and reopen it.

Expected: The news you read is not announced again.

## Check

### 4. No network

1. Put the phone in flight mode and open the app.

Expected: The app opens and works normally. Missing news is not an error worth blocking on, and must not stop the gallery loading.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 2: tapping a link should open the device browser. A screenshot after the tap shows which app is in front.
- To close the app completely on Android, use the system's recent apps screen or `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
- Flight mode is turned on and off from the quick settings panel, opened with a swipe down from the top edge, and tapped like the app.
