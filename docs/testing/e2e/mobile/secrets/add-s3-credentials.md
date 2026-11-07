# Mobile Manual Test: Add S3 Credentials

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test storing S3 credentials on the phone and using them to reach a database in a bucket.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- An S3 bucket, its region and endpoint, and a key pair that can read and write it. It is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. `start-minio` prints the endpoint, region and keys to type in at Test step 1.
- Test step 3 needs an S3 database: `--add test/test.jpg` creates one holding one photo, and `psi dbs send` sends its entry, `manual-test-s3db`. It prints a pairing code and waits: on the phone, go to the **Databases** page, choose **Receive database**, enter the code, and leave **Import S3 credentials** unticked, so that the database has to use the secret this test adds. In Test step 3, attach `manual-test-s3` to the entry (open its **⋮** menu, **Edit**, **Configure secrets…**) before opening it.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- manual-test-s3db --add test/test.jpg
source tmp/minio/manual-test-s3db.env
psi dbs send --name manual-test-s3db --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.
- The phone receives `manual-test-s3db`.

## Test

### 1. Add the credentials

1. Go to **Secrets** and add a secret of type S3 credentials.
2. Name it `manual-test-s3` and fill in the access key, secret key, region and endpoint.

Expected: It is saved and listed by name.

### 2. View it

1. Open the secret.

Expected:
- Each field is shown as you entered it.
- The secret key is hidden until you ask to see it.

### 3. Use it

1. Open an S3 database that uses this secret, as in [s3-database](../s3/s3-database.md).

Expected: The gallery loads, which is the only real proof the credentials were stored intact.

### 4. Edit it

1. Change the secret key to something wrong and save.
2. Close and reopen the S3 database.

Expected: The app says it cannot authenticate rather than showing an empty gallery.

## Check

### 5. Put it back

1. Correct the secret key.
2. Open the database again.

Expected: It works again, with no restart of the app needed.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- manual-test-s3db
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Leave **Import S3 credentials** unticked on the receive screen, as Prep says. Type the endpoint, region and keys `start-minio` printed with `input text`.
