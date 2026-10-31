# Mobile Manual Test: A Database Held in S3

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test opening and using a database whose storage is an S3 bucket rather than the phone.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- `--add test/test.jpg` creates the database `manual-test` holding one photo. `<bucket>` in the steps below is `photosphere-smoke-test`.
- `psi dbs send` sends the database entry with the S3 credentials attached, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code.
- `test.png` goes into the device photo library, for Test step 2 to import.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/test.png   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/test.png   # iOS
bun run ios   # iOS
bun run start-minio -- manual-test --add test/test.jpg
source tmp/minio/manual-test.env
psi dbs send --name manual-test --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The database is created in the bucket and the photo is added.
- The phone receives `manual-test` with `manual-test-s3`.

## Test

### 1. Open it

1. Open the S3 database on the phone.

Expected:
- The gallery loads and thumbnails appear.
- It is usable on a phone connection, not only on fast Wi-Fi: give it a moment rather than expecting it to be instant.

### 2. Import into it

1. Import a photo from the device.

Expected:
- The import completes and the photo appears in the gallery.
- It is in the bucket: check from the repo root, with the CLI on the PATH with `psi list --db s3:<bucket>/manual-test`.

### 3. Open a photo full size

1. Open a photo full screen.

Expected: The full photo loads from S3. A thumbnail that renders while the full photo never arrives is worth noting.

### 4. Lose the network mid-use

1. Put the phone in flight mode.
2. Scroll the gallery and open a photo.

Expected:
- The app says it cannot reach the storage.
- It does not crash, and does not show an empty gallery as though the database were empty.

### 5. Come back

1. Turn the network back on.
2. Scroll and open a photo again.

Expected: It recovers without the app being restarted.

## Check

### 6. Wrong credentials

1. Edit the S3 secret to something invalid.
2. Close and reopen the database.

Expected: The app says it cannot authenticate. It does not report an empty database.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- manual-test
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Step 6 edits the S3 secret with `input text`.
- Flight mode is turned on and off from the quick settings panel, opened with a swipe down from the top edge, and tapped like the app.
