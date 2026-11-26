# Manual Test: Onboarding by Creating a Remote Database From the App

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test a new user's first run of the app when they have an S3 bucket and no Photosphere database yet. Everything is done in the app: the user types their own S3 credentials, creates a new database in the bucket, takes a partial copy of it onto the device and switches on automatic import and syncing, so the device's photos end up in the bucket.

Run it on the mobile app (Android and iOS) and on the desktop app (Linux, macOS and Windows). The steps are the same on both. Where they differ, a line starts with **Mobile:** or **Desktop:**. On a mobile, automatic import reads the device photo library. On a desktop, it watches a photo folder.

## Prep

Run from the repo root. The CLI steps later in the test use the terminal the S3 server is started in.

### Mobile

- Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real mobile, clear the app's data instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- The device needs at least two photos in its photo library, for automatic import to find, and you need to be able to take one more with the camera partway through. On an emulator or simulator the commands below put two in.
- The mobile must be on Wi-Fi, on the same network as this machine. Syncing refuses a cellular connection by default.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/multiple-files/test-1.jpeg test/multiple-files/test-2.png   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/multiple-files/test-1.jpeg test/multiple-files/test-2.png   # iOS
bun run ios   # iOS
```

Expected: the reset prints that it wiped Photosphere's data, or that the app is not installed.

### Desktop

Open two terminals at the repo root, one for the desktop app and one for the CLI.

In the CLI terminal, make a fresh folder for this run, put two photos in the folder automatic import watches and print the folder's path:

```bash
export TEST_DIR="$(mktemp -d -t psi-onboard-new.XXXXXX)"
mkdir -p "$TEST_DIR/photos"
cp test/multiple-files/test-1.jpeg test/multiple-files/test-2.png "$TEST_DIR/photos/"
echo "$TEST_DIR"
```

In the app's terminal, set `TEST_DIR` to the path just printed:

```bash
export TEST_DIR=<the path printed above>
```

Run this in both terminals. It keeps the test's settings, secrets, cache, logs and the app's own data in the test's folder, away from other tests and from a normal install:

```bash
export PHOTOSPHERE_CONFIG_DIR="$TEST_DIR/config"
export PHOTOSPHERE_STATE_DIR="$TEST_DIR/config"
export PHOTOSPHERE_VAULT_DIR="$TEST_DIR/vault"
export PHOTOSPHERE_VAULT_TYPE=plaintext
export PHOTOSPHERE_CACHE_DIR="$TEST_DIR/cache"
export PHOTOSPHERE_LOG_DIR="$TEST_DIR/logs"
export XDG_DATA_HOME="$TEST_DIR/data"
```

`XDG_DATA_HOME` moves the app's data on Linux. On Windows use `export LOCALAPPDATA="$TEST_DIR/data"` in its place. On macOS the app's data cannot be moved this way, so quit any other copy of Photosphere before starting the test.

In the app's terminal, start the desktop app with the script for the platform you are on: `bun run linux`, `bun run macos` or `bun run windows`. It keeps running for the whole test:

```bash
bun run linux
```

Expected: the desktop app window opens.

### The S3 bucket

- **An S3 bucket with no Photosphere database in it.** It is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../minio.md). `--empty` makes the bucket and its credentials and creates no database.
- `start-minio` finishes by printing the endpoint, region, access key and secret key. **Keep them on screen.** Step 3 has you type them into the app.
- `$S3_DB` in the steps is the path the app creates the database at, `s3:photosphere-smoke-test/onboard-new`.

Run this on both. On a desktop, run it in the CLI terminal:

```bash
bun run start-minio -- onboard-new --empty
source tmp/minio/onboard-new.env
psi summary --db "$S3_DB"
```

Expected:
- `start-minio` prints the endpoint, region, access key and secret key.
- `psi summary` reports that no database was found at that path.

## Test

### 1. The app opens on its welcome screen

1. Open the app.

Expected:
- The app shows **Welcome to Photosphere**, with **New database**, **Open database** and **Add database**.
- No database is open.

### 2. Start creating the remote database

1. Choose **New database**.
2. **Name**: `my-remote`.
3. **Type**: **S3**.

Expected:
- The dialog shows an **S3 Credentials** row reading **None selected**, with a **Select** button.
- **Browse S3** beside **Path** is disabled until credentials are chosen.

### 3. Enter the S3 credentials

1. On the **S3 Credentials** row, choose **Select**.
2. Choose **Create new**.
3. **Name**: `my-remote-s3`.
4. Type the **Access Key ID**, **Secret Access Key**, **Region** and **Endpoint** exactly as `start-minio` printed them.
5. Choose **Create**.

Expected:
- The **S3 Credentials** row now reads `my-remote-s3`.
- **Browse S3** is enabled.

### 4. Choose where the database goes

1. Choose **Browse S3**.
2. **Bucket**: `photosphere-smoke-test`.
3. Choose the top of the bucket.
4. In **Path**, add `onboard-new` to the end, so it reads `s3:photosphere-smoke-test/onboard-new`.

Expected:
- The bucket is listed with no database in it. A refusal here means a credential was mistyped: go back to step 3 and check each field.
- **Path** reads `s3:photosphere-smoke-test/onboard-new`.

### 5. Create it

1. Leave **Encrypted** off.
2. Choose **Create**.

Expected: the dialog closes with no error and the app opens the new database, with an empty gallery.

### 6. Check the database is in the bucket

From the repo root:

```bash
psi summary --db "$S3_DB"
```

Expected: `psi summary` prints a summary of an empty database, where Prep reported that none was found.

### 7. Copy it onto the device

1. Open the menu and choose **Manage Databases**.
2. Choose the **⋮** on `my-remote`, then **Replicate**.
3. **Destination type**: **File system**.
4. **Destination path**:
    - **Mobile:** `my-photos`.
    - **Desktop:** the `TEST_DIR` path with `/my-photos` on the end.
5. **Mode**: **Partial**.
6. Choose **Start replication**.

Expected:
- It finishes in seconds.
- The dialog says "Replication completed." and the replica is listed on **Manage Databases**.

### 8. Make the copy the one the app uses

1. Choose the **⋮** on the replica, then **Set as default**.
2. Choose the **⋮** on the replica again, then **View details**.

Expected:
- **Origin** is `s3:photosphere-smoke-test/onboard-new`. Background syncing pushes to the origin, so a copy without one never syncs.

### 9. Open the copy

1. Open the menu, choose **Open database** and pick the replica.

Expected: the gallery is empty.

### 10. Switch on automatic import

1. Open the menu and choose **Configuration**.
2. **Desktop:** in the **Automatic import** card, choose **Add a folder** and pick the `photos` folder inside the `TEST_DIR` path.
3. Turn **Automatic import** on.
4. **Mobile:** allow access to **all** photos, then allow notifications.

Expected:
- The toggle stays on. On a mobile, a toggle that turns itself back off is a refused or partial permission.
- **Desktop:** the folder is listed under **Folders watched**.
- The app does not ask which database to import into: it uses the replica, the default set in step 8. A database called **My Photos** appearing instead means step 8 was missed.

### 11. Switch on syncing

1. Still in **Configuration**, turn **Enable syncing** on.

Expected:
- **Enable syncing** is on.
- **Only sync over Wi-Fi or wired network** is on. It refuses only a cellular connection, so a desktop on a wired connection still syncs.
- **Mobile:** the mobile is on Wi-Fi.

### 12. The device's own photos are imported

1. Go to the gallery and wait.

Expected:
- **Mobile:** photos from the device library appear, and stop appearing once the library has been walked.
- **Desktop:** the two photos from the folder appear.
- The app stays usable throughout.

### 13. The photos reach the bucket

1. Leave the app open and wait for a sync pass. Passes run every five minutes by default.
2. Check the bucket from the repo root:

```bash
psi summary --db "$S3_DB"
```

Expected: the bucket holds the photos the gallery shows, without anybody having asked for a sync.

### 14. A new photo reaches the bucket

1. Leave the app open.
2. Add a photo:
    - **Mobile:** take a photo with the camera, then switch back to Photosphere.
    - **Desktop:** in the CLI terminal, run `cp test/test.jpg "$TEST_DIR/photos/"`.
3. Go to the gallery.
4. After a sync pass, check the bucket from the repo root:

```bash
psi list --db "$S3_DB"
```

Expected:
- The photo appears in the gallery within about half a minute, without you importing it.
- After a sync pass it is listed in the bucket.

## Check

### 15. Check the photos are really there

Automatic import and syncing must both have caught up first. From the repo root:

```bash
psi verify --db "$S3_DB"
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery shows.

### 16. Clear up so the test can be run again

On a desktop, close the app first. The next run starts its own bucket, and its own folder or a reset app, so only the server has to be stopped:

```bash
bun run stop-minio -- onboard-new
```

Expected: it reports that MinIO stopped.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 3: type each credential from the `start-minio` output. On Android, use `input text`.
- Step 10 on a mobile brings up the system photos and videos permission: allow access to all photos, not a selection. Allow the notifications permission that follows. On a desktop, **Add a folder** opens the system folder picker: type the path to `$TEST_DIR/photos` into it.
- Step 14 on a mobile needs a photo taken with the camera, which the human does.
