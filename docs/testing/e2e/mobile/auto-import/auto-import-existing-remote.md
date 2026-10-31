# Mobile Manual Test: Automatic Import Into a Database That Already Exists

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

The other way round from [the new remote test](auto-import-new-remote.md). There the phone's database comes first and an empty remote is created to match it. Here the remote already exists, with a library in it, and the phone joins it by taking a copy: the credentials go to the phone, the app replicates the remote down as a partial replica, and automatic import and background syncing then run against that copy. This is what somebody with a Photosphere database already in a bucket does when they install the app on a phone.

The end state is the same as the other test's: one database in two places, the bucket recorded as the phone's origin, photos taken on the phone reaching the bucket on their own. What differs is the direction of the first move. Nothing is uploaded to join the two; the phone downloads a copy of what is already there.

## Prep

- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- **A Photosphere database that already exists in an S3 bucket, with photos in it.** It is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). `--from 50-assets` fills it with a copy of the `50-assets` test database (60 photos) and registers it on this machine as the entry `existing-remote-test`, with the credentials `existing-remote-test-s3`. The phone must be on the same network as this machine.
- `$S3_DB` in the steps is the database's path, `s3:photosphere-smoke-test/existing-remote-test`.
- `psi summary` checks the database reads, which also proves those are the right secrets.
- The device needs to be able to take a photo with the camera partway through.
- The phone must be on Wi-Fi. Syncing refuses a cellular connection by default, and a phone on mobile data will sit there doing nothing with no error.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- existing-remote-test --from 50-assets
source tmp/minio/existing-remote-test.env
psi summary --db "$S3_DB"
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- `psi summary` prints a summary rather than a report that no database was found. **Write down the number of photos it holds.** Later steps compare against it.

## Test

### 1. Check where the phone is starting from

1. Open the app.
2. Open the menu and go to the gallery.

Expected: no database is open, and there is nothing in the gallery.

### 2. Send the database to the phone

Each side waits sixty seconds for the other, which is not enough time to start the send and then walk to the phone, so the phone waits first and the pairing code is chosen in advance rather than generated.

Pick any four digits. On the phone:

1. Open the menu and choose **Manage Databases**.
2. Press the **⋮** at the top of the page and choose **Receive database**.
3. Enter the four digits and press **Start**.

Then, on the development machine, inside that minute, from the repo root, with the CLI on the PATH:

```bash
psi dbs send --name existing-remote-test --code <the four digits> --yes
```

Back on the phone:

4. On the review screen leave **Name** and **Path** exactly as they arrive. The path is how the phone finds the keys for the bucket and has to match character for character.
5. Tick **Import S3 credentials**, and **Import encryption key** if it is offered.
6. Press **Save**.

Expected:
- The phone says "Database imported successfully!" and the database appears on the Manage Databases page.
- The development machine says it sent the database.

"No device found within 60 seconds" means the window was missed or the two are not on the same network. Run the send again with the phone waiting.

### 3. Replicate it down onto the phone

1. On **Manage Databases**, press the **⋮** on the database that just arrived and choose **Replicate**.
2. **Destination type**: `File system`.
3. **Destination path**: type a short name, for example `my-photos`. It is created inside the app's own private storage; there is nothing on the phone's filesystem to browse to, and **Browse** on Android is a text prompt rather than a folder chooser.
4. **Mode**: **Partial**.
5. Press **Replicate**.

Expected:
- It finishes in seconds, however large the library is. A partial replication copies the README, the files merkle tree and the merkle trees of the record database, and nothing else: it deliberately does not walk the tree.
- **Nothing appears on the Manage Databases page.** A replication does not register its destination, so the list is unchanged. That is the next step.

### 4. Register the copy and make it the one the app uses

1. On **Manage Databases**, press the **⋮** at the top and choose **Add database**.
2. **Name**: whatever you want to see in the app. Entry names have to be unique, so if the name you want is the one the remote arrived under, rename the remote's entry first (**⋮** then **Edit** on it). Renaming an entry is safe: an origin is matched to its keys by path, never by name.
3. **Type**: `File system`. **Path**: the name typed in step 3.
4. Press **Add**.
5. Back on **Manage Databases**, press the **⋮** on it and choose **Set as default**.

Expected:
- The copy is listed and the app opens it.
- **Set as default** is what makes automatic import write into this database. Without it, switching automatic import on in step 6 makes a database of its own called **My Photos** and imports into that instead, because automatic import reads the default recorded in `config.yaml` and opening a database does not set it.
- **⋮** then **View details** on it shows **Origin** blank, and you have to set it: **⋮** then **Edit**, and beside **Origin** use the **Choose…** dropdown to pick the remote's entry, then Save. Do not type the path: credentials are matched to an origin by exact path, so a typo finds no keys and fails minutes later in a log rather than when you save.
- Setting it by hand is a gap rather than the intent. The replication records the origin in the copy's own `.db/config.json`, and the desktop refreshes the list entry from that whenever a database is opened, but mobile does not, so the field a phone shows stays empty. Origin is what background syncing looks for, and a database without it imports happily and never syncs.

### 5. The library appears on the phone

1. Go to the gallery.
2. Wait.

Expected:
- Photos from the remote appear, and the count climbs towards the number written down in Prep.
- **This takes a while, and the app looks empty while it happens.** The replication copied the trees and not the contents: opening a partial replica queues a prefetch that pulls the records and the thumbnails down from the bucket a few files at a time, and on a library of a few thousand photos that is minutes rather than seconds. An empty gallery a minute in is the prefetch still running, not a failure.
- The photos are browsable once they appear. The originals are still only in the bucket and are fetched when a photo is opened.

### 6. Set the phone importing into it

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card and turn the toggle on.
3. When the system asks for permission to read your photos, allow it, and allow **all** photos rather than a selection.

Expected:
- The toggle stays on. A toggle that turns itself back off is a refused or partial permission.
- On Android a notification appears saying **Backing up your photos**.
- The app does not ask which database to import into: it uses the one recorded as the default, which step 4 set to the copy. A database called **My Photos** appearing instead means step 4's **Set as default** was missed.

### 7. Check automatic syncing is on

1. Still in **Configuration**, look at the **Syncing** section.

Expected:
- **Enable syncing** is on. A fresh installation starts with it on, so this is a check rather than a change.
- **Only sync over Wi-Fi** is on, and the phone is on Wi-Fi.

### 8. The phone's own photos are imported

1. Go to the gallery.
2. Wait.

Expected:
- Photos from the device library appear alongside the ones that came down from the bucket.
- They keep appearing until the library has been walked, and then it stops.
- The app stays usable throughout.

### 9. A photo taken now goes the whole way

1. Leave the app open.
2. Take a photo with the camera.
3. Switch back to Photosphere and go to the gallery.
4. After a sync pass (passes run every five minutes by default), check the bucket from the repo root, with the CLI on the PATH:

```bash
psi summary --db "$S3_DB"
```

Expected:
- The photo appears in the gallery within about half a minute, without you importing it.
- After a sync pass it is in the bucket.
- The photo count is higher than the number written down in Prep, by what the phone has imported.

### 10. What was imported is recorded

1. Go to the **Import** page.

Expected:
- The photos the phone imported are listed, newest first, badged **automatic**.
- The photos that came down from the bucket are **not** listed. They were not imported on this device; they arrived by replication, and the import record is this device's record of what it took in.

### 11. The record survives a restart

1. Close the app completely and reopen it.
2. Open the copy made in step 4.
3. Go to the **Import** page.

Expected: the list still shows what this device imported, including from before the restart.

## Check

### 12. Check the photos are really there

Automatic import and syncing must both have caught up first. From the repo root, with the CLI on the PATH:

```bash
psi verify --db "$S3_DB"
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery shows.

A photo that shows in the gallery but fails verification has been recorded without its content being stored, which is the failure this step is here to catch.

### 13. Clear up so the test can be run again

The next run starts its own fresh bucket and resets the app, so only the server has to be stopped.

```bash
bun run stop-minio -- existing-remote-test
```

Expected: it reports that MinIO stopped.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 2: start receiving on the phone first, type the four digits with `input text`, then run `psi dbs send` within the minute.
- Step 6 brings up the system photos and videos permission: allow access to all photos, not a selection. If a notifications permission follows, allow it. The **Backing up your photos** notification is checked by pulling down the notification shade with a swipe from the top edge.
- Step 9 needs a photo taken with the camera, which the human does.
- Step 11: close the app completely from the system's recent apps screen, or with `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
