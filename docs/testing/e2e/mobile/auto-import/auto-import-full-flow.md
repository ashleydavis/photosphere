# Mobile Manual Test: Automatic Import, End to End

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the whole automatic photo backup flow on a phone: switching it on, the app making its own database, the photos already on the device being backed up, a photo taken while the app is running being backed up on its own, the record of what was imported, and the backup reaching a remote S3 bucket on its own through background syncing.

This is the flow the feature exists for, so it is worth running as one sitting rather than in pieces. It ends where a real backup ends: the photos off the phone and in the cloud, with nobody having pressed anything.

## Prerequisites

Run the app from source (from the repo root):

```bash
bun run and    # Android
bun run ios    # iOS
```

The device needs at least two photos in its photo library before you start, and you need to be able to take one more with the camera partway through.

An S3 bucket and its credentials, reachable from both the phone and your development machine. The later steps push the phone's backup into it and then read it back with the CLI.

The phone must be on Wi-Fi. Syncing refuses a cellular connection by default, and a phone on mobile data will sit there doing nothing with no error.

If the app has been used before, remove its data first so the test starts with no database and no settings. On Android: **Settings > Apps > Photosphere > Storage > Clear storage**. On iOS: delete the app and let `bun run ios` reinstall it.

## Steps

### 1. Check where you are starting from

1. Open the app.
2. Open the menu and go to the gallery.

Expected: No database is open, and there is nothing in the gallery.

---

### 2. Switch automatic import on

1. Open the menu and choose **Configuration**.
2. Find the **Automatic import** card.
3. Turn the toggle on.
4. When the system asks for permission to read your photos, allow it.

Expected:
- The toggle stays on.
- The app does not ask you to choose a database or a folder. There is nothing else to fill in.

---

### 3. The app makes its own database

1. Open the menu and choose **Open database**.

Expected:
- A database is listed that you did not create, holding the photos being backed up.
- Close the dialog without changing anything, or open that database to watch the rest of the test in the gallery.

---

### 4. The photos already on the device are backed up

1. Go to the gallery.
2. Wait. Photos already in the device library are worked through steadily rather than all at once, so give it a minute on a library of any size.

Expected:
- Photos from the device library appear in the gallery.
- They keep appearing until the library has been walked, and then it stops.
- The app stays usable throughout. Scrolling and navigating still work while the backup is running.

---

### 5. A photo taken now is backed up on its own

1. Leave the app open.
2. Switch to the camera app and take a photo.
3. Switch back to Photosphere and go to the gallery.

Expected:
- The new photo appears in the gallery without you importing it, and without reopening the database.
- It appears within about half a minute rather than only after a restart. Automatic import works in passes: a run reads the library, imports what is new and ends, and the app starts the next one a couple of seconds later, so a photo waits for the next pass rather than appearing the instant it is taken.

This is the part users notice: a photo taken a moment ago is already backed up.

---

### 6. See what was imported

1. Go to the **Import** page.

Expected:
- The photos that were backed up are listed, newest first.
- Each row is badged **automatic**.
- A count of what has been imported is shown while a backup is running.

---

### 7. The record survives a restart

1. Close the app completely and reopen it.
2. Open the database automatic import created.
3. Go to the **Import** page.

Expected:
- The list still shows what was imported, including from before the restart.
- The badges still say **automatic**.

This is the difference between a running total and a record: the app remembers what came in even though it was closed.

---

### 8. Switching it off stops it

1. Open the menu and choose **Configuration**.
2. Turn the **Automatic import** toggle off.
3. Take another photo with the camera.
4. Go back to the gallery.

Expected:
- The new photo does **not** appear.
- The photos already backed up are still there. Switching the feature off stops future backups and removes nothing.

---

### 9. Give the backup somewhere remote to go

Syncing pushes a database to its origin, and the origin has to exist already: a sync against a bucket with nothing in it reports the origin as unreachable rather than creating it.

Create the empty remote from `apps/cli/`:

```bash
bun run start -- init --db s3:<bucket>:/auto-sync-test --yes
```

Then on the phone:

1. Go to the **Databases** page.
2. Open the **⋮** menu on the database automatic import created and choose **Edit**.
3. Set **Origin** to `s3:<bucket>:/auto-sync-test`.
4. Press **Configure secrets…** and set **S3 Credentials** to the bucket's credentials. Use **+ New** to enter them if the phone does not have them yet.
5. Save.

Expected:
- The origin is accepted and shown against the database on the Databases page.
- Nothing else is asked for. Syncing needs no separate setup of its own.

---

### 10. Check automatic syncing is on

1. Open the menu and choose **Configuration**.
2. Look at the **Syncing** section.

Expected:
- **Enable syncing** is on. A fresh installation starts with it on, so this is a check rather than a change.
- **Only sync over Wi-Fi** is on, and the phone is on Wi-Fi.

---

### 11. The backup reaches the bucket on its own

1. Leave the app open and wait. Passes run every five minutes by default, so give it that long before deciding nothing is happening.

Check the bucket from `apps/cli/`:

```bash
bun run start -- summary --db s3:<bucket>:/auto-sync-test
```

Expected:
- The photos backed up on the phone are in the bucket, without anybody having asked for a sync.
- The count climbs across passes if automatic import is still catching up, rather than arriving all at once.

Nothing on the phone was pressed to make this happen. That is the point of the step: a photo taken on the phone ends up in the cloud with no user action anywhere in the chain.

---

### 12. Check the photos are really there

Automatic import and syncing must both have caught up before the counts can match. While either is still working the numbers keep moving, so turn the **Automatic import** toggle off, wait for one more sync pass, and note the count in the gallery you are comparing against.

From `apps/cli/`:

```bash
bun run start -- verify --db s3:<bucket>:/auto-sync-test
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery showed.

A photo that shows in the gallery but fails verification has been recorded without its content being stored, which is the failure this step is here to catch.

---

### 13. A new photo goes the whole way, with nothing else in the way

The last step, and it needs a quiet phone: the existing library fully imported and the bucket already caught up, as step 12 has just established. Everything up to here has been about a backlog; this is the app doing its ordinary day-to-day job.

1. Open the menu, choose **Configuration**, and turn **Automatic import** back on. Step 12 turned it off.
2. Take a photo with the camera.
3. Switch back to Photosphere and go to the gallery.

Expected:
- The photo appears in the gallery within about half a minute. Nothing is queued ahead of it now, so it does not wait for a batch to fill the way it does during the first backup.
- After a sync pass it is in the bucket. Check from `apps/cli/`:

```bash
bun run start -- list --db s3:<bucket>:/auto-sync-test
```

Camera to cloud, with the app only ever left open. This is what the feature is for, and it is the step to run when the earlier ones have been slow: a phone that has finished backfilling should handle a new photo promptly even if the first backup took hours.
