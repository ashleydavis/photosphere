# Mobile Manual Test: Replicate a Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test copying a database from the phone to another location, and that the copy is complete and verifiable.

## Prep

- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `test.png` goes into the device photo library, for Test step 4 to import.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- The destination is the database path `start-minio` prints, `s3:photosphere-smoke-test/replica`. `--empty` leaves nothing there, so the replication creates it.
- `psi secrets send` sends the bucket's credentials, `replica-s3`, to the phone, prints a pairing code and waits. On the phone, go to **Secrets**, start receiving and enter the code.
- `test/dbs/50-assets` is the source the CLI compares against in Test step 2, the same database Android loads.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/test.png   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/test.png   # iOS
bun run ios:50   # iOS
bun run start-minio -- replica --empty
source tmp/minio/replica.env
psi secrets send --name replica-s3 --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The S3 server starts, and the phone receives `replica-s3`.
- A database is open on the phone with a few photos in it.

## Test

### 1. Replicate it

1. Start a replication from the phone to the destination, `s3:photosphere-smoke-test/replica`, with `replica-s3` as its S3 credentials.
2. Wait for it to finish.

Expected:
- Progress is shown while it runs.
- It reports completion rather than stopping silently.

### 2. Check the copy

From the repo root, with the CLI on the PATH (on iOS the source is not reachable from the machine, so skip `compare` there):

```bash
psi verify --db "$S3_DB"
psi compare --db test/dbs/50-assets --dest "$S3_DB"
```

Expected:
- Verification passes with no failures.
- The comparison reports the two as the same.

### 3. Replicate again with nothing changed

1. Run the same replication a second time.

Expected: It completes quickly and copies little or nothing. A replication that copies everything again every time is worth noting.

### 4. Replicate after a change

1. Import one more photo on the phone: on the **Import** page, choose `test.png`.
2. Replicate again.

Expected: Only the new photo is copied, and the destination then holds it.

## Check

### 5. Interrupt one

1. Start a replication of a larger database and put the phone in flight mode partway.

Expected:
- The app says the replication failed rather than reporting success.
- Running it again once the network is back completes it, rather than starting from nothing.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- replica
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi secrets send` prints is typed on the phone with `input text`. The destination path in step 1 is typed the same way.
- Flight mode is turned on and off from the quick settings panel, opened with a swipe down from the top edge, and tapped like the app.
