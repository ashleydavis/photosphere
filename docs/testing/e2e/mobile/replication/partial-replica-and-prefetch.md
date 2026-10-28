# Mobile Manual Test: A Partial Replica and Fetching Originals Back

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test a database on the phone that holds only part of what the remote holds: the gallery still shows everything, and an original is fetched back when it is opened.

This is what lets a phone carry a collection larger than the phone.

## Prep

- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- The remote is filled with a copy of the `50-assets` test database (`--from 50-assets`).
- `psi dbs send` sends the remote's entry and its credentials to the phone, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code.
- Then make the partial replica on the phone: open `mobile-test-remote`, use **Replicate** with **Partial** to copy it to a new folder on the phone, and open that copy. A replica's origin is the database it was replicated from, so its origin is the remote and it holds photos the phone has not downloaded.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- mobile-test-remote --from 50-assets
source tmp/minio/mobile-test-remote.env
psi dbs send --name mobile-test-remote --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The S3 server starts and the replication completes.
- The partial replica is open on the phone, with `mobile-test-remote` as its origin.

## Test

### 1. See what the remote holds

1. Open the database on the phone and let it sync.

Expected:
- The gallery shows every photo in the remote, including ones whose originals are not on the phone.
- Thumbnails appear for them.

### 2. Open one the phone does not hold

1. Open a photo whose original has not been downloaded.

Expected:
- The full photo is fetched and shown.
- It takes longer than one already on the phone, and says so or shows progress rather than appearing to hang.

### 3. Open it again

1. Close the photo and open it again.

Expected: It appears immediately the second time.

### 4. Open one with no network

1. Put the phone in flight mode.
2. Open a photo whose original is not on the phone.

Expected:
- The app says it cannot fetch it.
- It does not show a blank screen with no explanation, and the photos the phone does hold still open.

## Check

### 5. Check the phone did not lose the remote's photos

1. Turn the network back on and let it sync.

From the repo root, with the CLI on the PATH:

```bash
psi summary --db "$S3_DB"
```

Expected: The remote still holds everything it did. A phone that holds part of a database must never delete from the remote what it chose not to download.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-remote
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- The partial replica in Prep is made with taps in the app: **Replicate**, **Partial**, a folder name typed with `input text`.
- Flight mode is turned on and off from the quick settings panel, opened with a swipe down from the top edge, and tapped like the app.
