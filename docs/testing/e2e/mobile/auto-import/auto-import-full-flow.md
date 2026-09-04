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

The CLI commands below name the bucket by a raw `s3:` path, which carries no stored credentials with it, so it uses the environment. On anything other than real AWS, `AWS_ENDPOINT` has to be exported as well, or the command goes to AWS and reports that the bucket does not exist.

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

### 8. Give the backup somewhere remote to go

Syncing pushes a database to its origin, and the origin has to exist already: a sync against a bucket with nothing in it reports the origin as unreachable rather than creating it.

Create the empty remote from `apps/cli/`:

```bash
bun run start -- init --db s3:cloud-storage-tests/auto-sync-test --yes
```

Now the phone needs to know that path, and needs credentials for it. Take either route below. They end in the same place, so run one, not both.

#### Route A: type it into the phone

1. Go to the **Databases** page.
2. Open the **⋮** menu on the database automatic import created and choose **Edit**.
3. Set **Origin** to `s3:cloud-storage-tests/auto-sync-test`.
4. Press **Configure secrets…** and set **S3 Credentials** to the bucket's credentials. Use **+ New** to enter them if the phone does not have them yet, filling in the endpoint as well as the keys.

    A phone has no environment to fall back on, so the endpoint belongs in the secret. For a bucket that is not on real AWS this is the field that decides whether anything works at all.

5. Save.

#### Route B: set it up on the development machine and send it over

Typing an access key and a secret on a phone keyboard is the slowest part of this test. The CLI can hold them instead and hand them over the local network. Both devices must be on the same network.

From `apps/cli/`, make the secret and the database entry:

```bash
bun run start -- secrets add --yes --name auto-sync-test-s3 --type s3-credentials \
  --value '{"endpoint":"https://<region>.digitaloceanspaces.com","region":"us-east-1","accessKeyId":"<access key id>","secretAccessKey":"<secret access key>"}'

bun run start -- dbs add --yes --name auto-sync-test \
  --path s3:cloud-storage-tests/auto-sync-test --s3-cred auto-sync-test-s3
```

Then send them together. `dbs send` carries the database entry and the secrets attached to it, so the secret does not have to be sent separately:

```bash
bun run start -- dbs send --name auto-sync-test --yes
```

`--yes` is what makes it go straight to a pairing code. Without it the command walks through the name, description and path one field at a time, offering to edit each, before it sends anything.

It prints the pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database**, and enter that code.

Then set the origin, which is the one thing that still has to be done on the phone:

1. Open the **⋮** menu on the database automatic import created and choose **Edit**.
2. Set **Origin** to `s3:cloud-storage-tests/auto-sync-test`.
3. Press **Configure secrets…** and set **S3 Credentials** to `auto-sync-test-s3`, which arrived with the database.
4. Save.

Expected, either route:
- The origin is accepted and shown against the database on the Databases page.
- Nothing else is asked for. Syncing needs no separate setup of its own.

---

### 9. Check automatic syncing is on

1. Open the menu and choose **Configuration**.
2. Look at the **Syncing** section.

Expected:
- **Enable syncing** is on. A fresh installation starts with it on, so this is a check rather than a change.
- **Only sync over Wi-Fi** is on, and the phone is on Wi-Fi.

---

### 10. The backup reaches the bucket on its own

1. Leave the app open and wait. Passes run every five minutes by default, so give it that long before deciding nothing is happening.

Check the bucket from `apps/cli/`:

```bash
bun run start -- summary --db s3:cloud-storage-tests/auto-sync-test
```

Expected:
- The photos backed up on the phone are in the bucket, without anybody having asked for a sync.
- The count climbs across passes if automatic import is still catching up, rather than arriving all at once.

Nothing on the phone was pressed to make this happen. That is the point of the step: a photo taken on the phone ends up in the cloud with no user action anywhere in the chain.

---

### 11. Switching it off stops it

Automatic import comes off here rather than earlier, because everything above needed it running: the library had to be backed up and the backup had to reach the bucket before there was anything worth checking.

1. Open the menu and choose **Configuration**.
2. Turn the **Automatic import** toggle off.
3. Take another photo with the camera.
4. Go back to the gallery.

Expected:
- The new photo does **not** appear.
- The photos already backed up are still there. Switching the feature off stops future backups and removes nothing.

---

### 12. Check the photos are really there

Automatic import and syncing must both have caught up before the counts can match. Step 11 has just switched importing off, so wait for one more sync pass and note the count in the gallery you are comparing against.

From `apps/cli/`:

```bash
bun run start -- verify --db s3:cloud-storage-tests/auto-sync-test
```

Expected:
- Verification completes without errors.
- The number of files matches what the gallery showed.

A photo that shows in the gallery but fails verification has been recorded without its content being stored, which is the failure this step is here to catch.

---

### 13. A new photo goes the whole way, with nothing else in the way

This one needs a quiet phone: the existing library fully imported and the bucket already caught up, as step 12 has just established. Everything up to here has been about a backlog; this is the app doing its ordinary day-to-day job.

1. Open the menu, choose **Configuration**, and turn **Automatic import** back on. Step 11 turned it off.
2. Take a photo with the camera.
3. Switch back to Photosphere and go to the gallery.

Expected:
- The photo appears in the gallery within about half a minute. Nothing is queued ahead of it now, so it does not wait for a batch to fill the way it does during the first backup.
- After a sync pass it is in the bucket. Check from `apps/cli/`:

```bash
bun run start -- list --db s3:cloud-storage-tests/auto-sync-test
```

Camera to cloud, with the app only ever left open. This is what the feature is for, and it is the step to run when the earlier ones have been slow: a phone that has finished backfilling should handle a new photo promptly even if the first backup took hours.

---

### 14. Clear up so the test can be run again

The test starts from a phone with no database and a bucket with nothing at that prefix, so both have to go back to how they were. Leaving them means the next run silently tests something else: a second run against a bucket that already holds the photos syncs nothing and proves nothing.

1. Delete everything under the `auto-sync-test` prefix in the bucket. Do this from the Spaces or S3 console, or with an S3 client. The CLI has no command for it: `psi dbs remove` takes the database out of the list and leaves its files where they are.
2. On the phone, remove the app's data. On Android: **Settings > Apps > Photosphere > Storage > Clear storage**. On iOS: delete the app.
3. Take the bucket's credentials off the development machine, and the database entry with them. Route B put them there, and a live access key left in a keychain outlives the test that needed it. From `apps/cli/`:

```bash
bun run start -- dbs remove --yes --name auto-sync-test
bun run start -- secrets remove --yes --name auto-sync-test-s3
```

    Skip this if you took Route A, which never put anything on the development machine.

Confirm the bucket is clear, from `apps/cli/`:

```bash
bun run start -- summary --db s3:cloud-storage-tests/auto-sync-test
```

Expected: it reports that no database was found at that path, which is the state step 8 starts from.
