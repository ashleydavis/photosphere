# Mobile Manual Test: Open an Encrypted Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database encrypted with a key opens on the phone when the key is in the vault, and refuses when it is not.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- `--encrypt --add test/test.jpg` creates an encrypted database holding one photo, with a key generated for it, `mobile-test-encrypted-key`, attached to the entry.
- To receive the key again in Test step 4, run `psi secrets send --name mobile-test-encrypted-key --yes` in the same terminal.
- `psi dbs send` sends the database entry with the key and the S3 credentials attached, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- mobile-test-encrypted --encrypt --add test/test.jpg
source tmp/minio/mobile-test-encrypted.env
psi dbs send --name mobile-test-encrypted --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The encrypted database is created and the photo is added.
- The phone receives `mobile-test-encrypted`, with `mobile-test-encrypted-key` and `mobile-test-encrypted-s3`.

## Test

### 1. Open it with the key present

1. Check the key is listed under **Secrets** on the phone.
2. Open the database.

Expected:
- The gallery loads and the photos are shown.
- Thumbnails render rather than showing broken images.

### 2. Open a photo

1. Open one of the photos full screen.

Expected: The full photo loads. Decryption happens on the phone, so a photo that shows as a thumbnail and fails full screen is worth noting here.

### 3. Open it without the key

1. Delete the key from **Secrets**.
2. Close the database and open it again.

Expected:
- The app says it cannot open the database, or that the key is missing.
- It does not show an empty gallery as though the database had no photos, and it does not crash.

## Check

### 4. Put the key back

1. Receive the key again.
2. Open the database.

Expected: The photos are back, unchanged.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-encrypted
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Step 4 receives the key with `psi secrets send`: start receiving on the phone, then type the code.
