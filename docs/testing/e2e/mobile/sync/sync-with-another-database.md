# Mobile Manual Test: Sync With Another Copy of a Database

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that changes made on the phone reach another copy of the database, and that changes made there reach the phone.

## Prep

- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- `test.png` goes into the device photo library, for Test step 1 to import.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- The other copy is filled with a copy of the `50-assets` test database (`--from 50-assets`), so it shares that database's identity and the two can sync.
- `psi dbs send` sends the other copy's entry and its credentials to the phone, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code.
- `bun run android:50` and `bun run ios:50` put the `50-assets` test database on the device as `test-50-assets` and open it on launch.
- Then set the origin of the open database: on the **Databases** page, open its **⋮** menu, choose **Edit**, pick `mobile-test-remote` from the **Choose…** dropdown beside **Origin**, and save.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/test.png   # Android
bun run android:50   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/test.png   # iOS
bun run ios:50   # iOS
bun run start-minio -- mobile-test-remote --from 50-assets
source tmp/minio/mobile-test-remote.env
psi dbs send --name mobile-test-remote --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- The S3 server starts and the replication completes.
- A database is open on the phone with its origin set to `mobile-test-remote`, a copy you can reach from your development machine.

## Test

### 1. Add a photo on the phone

1. Import a photo you will recognise: on the **Import** page, choose `test.png`.
2. Let the phone sync.

Check the other copy from the repo root, with the CLI on the PATH:

```bash
psi list --db "$S3_DB"
```

Expected: The photo is listed there.

### 2. Add a photo on the other side

From the repo root, with the CLI on the PATH:

```bash
psi add test/test.jpg --db "$S3_DB"
```

Then let the phone sync and open the gallery.

Expected: The photo appears on the phone without the database being closed and reopened.

### 3. Edit on one side

1. Edit a photo's description on the phone.
2. Let it sync, then read that asset from the other copy.

Expected: The description is there.

### 4. Delete on one side

1. Delete a photo on the phone.
2. Let it sync.

Expected: It goes from the other copy too, and does not come back on the next sync.

## Check

### 5. Both sides changed at once

1. Put the phone in flight mode.
2. Add a photo on the phone, and a different one on the other copy.
3. Bring the phone back online and let it sync.

Expected: Both photos end up in both copies. Neither side wins by discarding the other's work.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-remote
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Setting the origin in Prep is taps in the app: **⋮**, **Edit**, the **Choose…** dropdown beside **Origin**, **Save**.
- Step 3 types the description with `input text`.
- Flight mode is turned on and off from the quick settings panel, opened with a swipe down from the top edge, and tapped like the app.
