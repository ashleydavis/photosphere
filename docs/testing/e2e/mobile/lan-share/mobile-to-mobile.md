# Mobile Manual Test: LAN Share, Phone to Phone

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test one phone sending a database entry and a secret to another phone on the same network. This is the only one of the three LAN tests where a phone is the sender as well as the target.

## Prep

- Two devices, both running the app from source.
- Do the reset on both devices: run the block once for each, with `PHOTOSPHERE_ANDROID_TARGET` set to that emulator's serial on Android.
- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- Both must be on the same local network, on Wi-Fi rather than mobile data. This does not work over the internet.
- Run it at least once with both phones on the same platform, and once with one Android and one iOS, since the two implementations only meet here.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
```

- Call the phones A and B. A sends the secret in Test step 1 and B sends the database entry in Test step 2, so each needs something to send after the reset:
  - On A, go to **Secrets** and add a secret, `m2m-secret`, of type API key with any value.
  - B gets an S3 database entry, so that opening it on A reaches the same storage. S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). `psi dbs send` prints a pairing code and waits: on B, go to the **Databases** page, choose **Receive database**, enter the code and save.

```bash
bun run start-minio -- mobile-test-m2m --from 1-asset
source tmp/minio/mobile-test-m2m.env
psi dbs send --name mobile-test-m2m --yes
```

Expected:
- On both devices, the reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.
- A lists `m2m-secret`, and B lists `mobile-test-m2m`.

## Test

### 1. Send a secret from one phone to the other

1. On A, open the **⋮** menu of `m2m-secret`, choose **Share** and **Send**. Note the pairing code it shows.
2. On B, go to **Secrets**, start receiving and enter that code.

Expected:
- The receiving phone finds the sender within a few seconds.
- The secret arrives with the same name and value.
- Neither phone is left showing a progress spinner after it completes.

### 2. Send a database entry the other way

1. On B, share `mobile-test-m2m` and note the pairing code it shows.
2. On A, start receiving a database entry and enter that code.

Expected:
- The entry arrives and is listed.
- Opening it reaches the same storage, so the photos are the same on both phones.

### 3. Both phones on mobile data

1. Turn Wi-Fi off on both phones.
2. Try to share.

Expected: The devices do not find each other and both say so after their own timeout. Neither claims success.

### 4. The wrong code

1. Share from one phone and note its code.
2. Start receiving on the other and enter a different code.

Expected: Nothing is transferred, and the receiving phone says a device was found using a different code rather than appearing to hang.

## Check

### 5. Cancel from each side

1. Start a share and cancel it on the sender.
2. Start another and cancel it on the receiver.

Expected: Both end cleanly, and a further share works straight away without either app being restarted.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-m2m
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Two devices: on Android pass each one's own serial with `-s`. With one Android and one iOS device, the agent drives the Android one and the human the iOS one.
- Step 3 turns Wi-Fi off from the quick settings panel, opened with a swipe down from the top edge.
