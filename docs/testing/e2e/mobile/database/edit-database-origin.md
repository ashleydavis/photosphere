# Mobile Manual Test: Point a Database at a Remote

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test setting a database's origin on the phone, so it syncs with a remote copy.

## Prep

- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- The remote is filled with a copy of the `50-assets` test database (`--from 50-assets`), so it shares that database's identity and the two can sync.
- `psi dbs send` sends the remote's entry and its credentials to the phone, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch. That is the database the test sets the origin on.

```bash
bun run android:reset   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:50   # iOS
bun run start-minio -- mobile-test-remote --from 50-assets
source tmp/minio/mobile-test-remote.env
psi dbs send --name mobile-test-remote --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The S3 server starts and the replication completes.
- The phone receives `mobile-test-remote`, and a database is open on the phone.

## Test

### 1. Set the origin

1. Open the database's details.
2. Set its origin to the remote copy, `mobile-test-remote`.

Expected: The setting is accepted and shown.

### 2. Check it stuck

1. Close the app completely and reopen it.
2. Open the same database and its details.

Expected: The origin is still what you set.

### 3. Sync to the remote

1. Trigger a sync, or wait for the periodic one.

Expected:
- Photos on the phone appear in the remote copy.
- Photos added to the remote appear on the phone.

Check the remote from the repo root, with the CLI on the PATH:

```bash
psi summary --db "$S3_DB"
```

## Check

### 4. A remote that is not reachable

1. Set the origin to something that does not exist.
2. Trigger a sync.

Expected: The app says the sync failed and why. It does not report success, and it does not hang with no explanation.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-remote
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Step 4 types a made-up origin with `input text`.
