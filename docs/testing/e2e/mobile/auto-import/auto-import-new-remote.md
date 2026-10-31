# Mobile Manual Test: Automatic Import, End to End

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the whole flow on a phone, from the camera roll to the cloud: switching automatic import on, the app making its own database, the photos already on the device being imported into it, a photo taken while the app is running being imported on its own, the record of what was imported, and then the database being backed up to a remote S3 bucket on its own through background syncing.

This is the flow the feature exists for, so it is worth running as one sitting rather than in pieces. It ends where a real backup begins: the photos off the phone and in the cloud, with nobody having pressed anything. Everything before that is the on-device database being built, which is not a backup at all, because losing the phone loses it.

## Prep

- The device needs at least two photos in its photo library before you start, and you need to be able to take one more with the camera partway through. On an emulator or simulator the Prep commands put two in.
- The phone must be on Wi-Fi. Syncing refuses a cellular connection by default, and a phone on mobile data will sit there doing nothing with no error.
- Run from the repo root, in one terminal, which the later CLI steps use too. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. The later steps back the phone up into it and then read that copy with the CLI.
- `--empty` leaves the prefix empty, which Test step 8 needs, and registers the entry `auto-sync-test` with the credentials `auto-sync-test-s3` on this machine. `start-minio` prints the endpoint, region and keys, for Test step 8 Route A. `$S3_DB` in the steps is the database's path, `s3:photosphere-smoke-test/auto-sync-test`.

```bash
bun run android:reset   # Android
bun run android:add-fixtures -- test/multiple-files/test-1.jpeg test/multiple-files/test-2.png   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios:add-fixtures -- test/multiple-files/test-1.jpeg test/multiple-files/test-2.png   # iOS
bun run ios   # iOS
bun run start-minio -- auto-sync-test --empty
source tmp/minio/auto-sync-test.env
psi summary --db "$S3_DB"
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- `psi summary` reports that no database was found at that path.

## Test

### 1. Check where you are starting from

1. Open the app.
2. Open the menu and go to the gallery.

Expected: No database is open, and there is nothing in the gallery.

### 2. Switch automatic import on

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card.
3. Turn the toggle on.
4. When the system asks for permission to read your photos, allow it.

Expected:
- The toggle stays on.
- The app does not ask you to choose a database or a folder. There is nothing else to fill in.

### 3. The app makes its own database

1. Open the menu and choose **Open database**.

Expected:
- A database is listed that you did not create, holding the photos being imported.
- Close the dialog without changing anything, or open that database to watch the rest of the test in the gallery.

### 4. The photos already on the device are imported

1. Go to the gallery.
2. Wait. Photos already in the device library are worked through steadily rather than all at once, so give it a minute on a library of any size.

Expected:
- Photos from the device library appear in the gallery.
- They keep appearing until the library has been walked, and then it stops.
- The app stays usable throughout. Scrolling and navigating still work while the import is running.

### 5. A photo taken now is imported on its own

1. Leave the app open.
2. Switch to the camera app and take a photo.
3. Switch back to Photosphere and go to the gallery.

Expected:
- The new photo appears in the gallery without you importing it, and without reopening the database.
- It appears within about half a minute rather than only after a restart. Automatic import works in passes: a run reads the library, imports what is new and ends, and the app starts the next one a couple of seconds later, so a photo waits for the next pass rather than appearing the instant it is taken.

### 6. See what was imported

1. Go to the **Import** page.

Expected:
- The photos that were imported are listed, newest first.
- Each row is badged **automatic**.
- A count of what has been imported is shown while an import is running.

### 7. The record survives a restart

1. Close the app completely and reopen it.
2. Open the database automatic import created.
3. Go to the **Import** page.

Expected:
- The list still shows what was imported, including from before the restart.
- The badges still say **automatic**.

### 8. Get the credentials for the bucket onto the phone

The bucket prefix must be empty before this step. Do **not** create a database in it with `psi init` yet: a database made without the phone's id is a stranger to the one on the phone, and sync refuses to join two databases that are not related.

The phone needs credentials for the bucket, and no environment variables reach it, so the endpoint has to be part of the secret. Take either route below, not both.

#### Route A: type them into the phone

1. Go to the **Databases** page.
2. Open the **⋮** menu on the database automatic import created and choose **Edit**.
3. Press **Configure secrets…**, then **+ New** beside **S3 Credentials**, and fill in the endpoint, region and keys that `start-minio` printed.
4. Save.

#### Route B: send them from the development machine

`start-minio` already made the entry `auto-sync-test` and its credentials `auto-sync-test-s3` on this machine. `dbs send` carries the entry and the secrets attached to it. `--yes` makes it go straight to a pairing code:

```bash
psi dbs send --name auto-sync-test --yes
```

It prints the pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database**, and enter that code.

Expected, either route: the phone holds a secret with the bucket's endpoint and keys.

### 9. Make an empty remote that the phone can sync into

Two databases can sync only when they share an identity, a single uuid held in the merkle tree. So the remote is created empty, carrying the phone's identity, and left for the background sync to fill.

Get the phone's database id from the **Database ID** row of **Database Info** in the sidebar, then from the repo root, with the CLI on the PATH:

```bash
psi init --db "$S3_DB" --database-id <the phone's database id> --yes
psi database-id --db "$S3_DB"
```

Expected:
- `init` reports that it created the database.
- `database-id` prints the same id the phone has.
- A mistyped id is refused rather than accepted.

### 10. Point the phone at the remote

1. Open the **⋮** menu on the database automatic import created and choose **Edit**.
2. Beside **Origin**, use the **Choose…** dropdown and pick the entry for the bucket. Do not type the path: the credentials for an origin are found by matching its path against the database list, so a typed path with a mistake in it finds no entry and no credentials.
3. Save.

Expected:
- The origin is accepted and shown against the database on the Databases page.
- Nothing else is asked for. Syncing needs no separate setup of its own.

### 11. Check automatic syncing is on

1. Open the menu and choose **Configuration**.
2. Look at the **Syncing** section.

Expected:
- **Enable syncing** is on. A fresh installation starts with it on, so this is a check rather than a change.
- **Only sync over Wi-Fi** is on, and the phone is on Wi-Fi.

### 12. The backup reaches the bucket on its own

1. Leave the app open and wait. Passes run every five minutes by default, so give it that long before deciding nothing is happening.
2. Check the bucket from the repo root, with the CLI on the PATH:

```bash
psi summary --db "$S3_DB"
```

Expected:
- The photos on the phone are in the bucket, without anybody having asked for a sync.
- The count climbs across passes if automatic import is still catching up, rather than arriving all at once.

### 13. Switching it off stops it

1. Open the menu and choose **Configuration**.
2. Turn the **Automatic import** toggle off.
3. Take another photo with the camera.
4. Go back to the gallery.

Expected:
- The new photo does **not** appear.
- The photos already imported are still there. Switching the feature off stops future imports and removes nothing.

## Check

### 14. Check the photos are really there

Automatic import and syncing must both have caught up before the counts can match. Test step 13 has just switched importing off, so wait for one more sync pass and note the count in the gallery you are comparing against.

From the repo root, with the CLI on the PATH:

```bash
psi verify --db "$S3_DB"
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery showed.

A photo that shows in the gallery but fails verification has been recorded without its content being stored.

### 15. A new photo goes the whole way, with nothing else in the way

This needs a quiet phone: the existing library fully imported and the bucket already caught up, as step 12 established.

1. Open the menu, choose **Configuration**, and turn **Automatic import** back on. Test step 13 turned it off.
2. Take a photo with the camera.
3. Switch back to Photosphere and go to the gallery.
4. After a sync pass, check the bucket from the repo root, with the CLI on the PATH:

```bash
psi list --db "$S3_DB"
```

Expected:
- The photo appears in the gallery within about half a minute. Nothing is queued ahead of it now, so it does not wait for a batch to fill the way it does while the library is still being imported.
- After a sync pass it is in the bucket.

### 16. Clear up so the test can be run again

The next run starts its own fresh bucket and resets the app, so only the server has to be stopped.

```bash
bun run stop-minio -- auto-sync-test
```

Expected: it reports that MinIO stopped.

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- Step 2 brings up the system photos and videos permission: allow it, with access to all photos rather than a selection. If a notifications permission follows, allow it.
- Steps 5, 13 and 15 need a photo taken with the camera, which the human does.
- Step 7: close the app completely from the system's recent apps screen, or with `adb -s <serial> shell am force-stop au.com.codecapers.photosphere.ziggy`, then open it again from the launcher.
- Step 8 Route A: type the endpoint, region and keys that `start-minio` printed with `input text`. Route B: read the pairing code from the CLI output and type it on the phone.
- Step 9 needs the phone's database id, read from the **Database ID** row of **Database Info** on the phone with a screenshot.
