Auto import and sync test

A test on a real Android mobile of automatic import and background syncing to S3, from a mobile with no Photosphere data to every photo on it being in the bucket. It measures how long import and sync take on a whole photo library and whether everything arrives, which no smoke test can do, since the smoke tests use a handful of fixture photos on emulators.

Commands

- /test:auto-import-sync:start (start.md): resets the last run and starts a new one. It first asks whether to run automatically or manually. Automatic does every step, including tapping through the app on the mobile. Manual does the reset and the setup on this machine, then walks you through the steps on the mobile one at a time. It shows what the reset deletes and asks twice before deleting anything.
- /test:auto-import-sync:check (check.md): reports whether import and sync are still going or have finished, with the counts, anything missing and how long each took. It only reads.
- /test:auto-import-sync:verify (verify.md): checks the result once import and sync have finished. It ends at once when either is still going. It copies the replica off the mobile into tmp/, writes a CSV of every asset imported on the mobile to docs/testing/auto-import-sync/, checks each row against the remote database and marks it with a tick and the remote's hash, runs a full verify of the local and the remote database, and compares the two. It ends with a short summary of the CSV's path, how many assets the remote confirms, the verify results and whether the databases match.

What it sets up

- The remote database: a folder named psi-test-<number> in the test bucket photosphere-test-bucket-1, holding one photo. Each run gets the next number, so a run never shares a folder with the one before it.
- The database entry: do-test, on this machine and on the mobile. Its S3 credentials come from the vault secret default:s3.
- The local copy: a partial replica of do-test on the mobile, named my-photos. It is the default database, so automatic import writes into it, and its origin is do-test, so syncing pushes what it imports to the bucket.
- The mobile's settings: automatic import and syncing switched on, syncing only over Wi-Fi.

Running it

1. Plug the mobile in over USB with debugging allowed, and put it on Wi-Fi.
2. Run /test:auto-import-sync:start. The reset uninstalls Photosphere from the mobile, which deletes every database it holds there, and deletes the previous run's folder from the bucket. The mobile's own photos are never touched, and the command checks the device's photo count is the same afterwards.
3. Leave the mobile on Wi-Fi. It can be unplugged.
4. Run /test:auto-import-sync:check whenever you want to know where it is.

What the check compares

- Import: the device's photo and video count against what the last automatic import pass found already imported or failed to import.
- Sync: the names of the originals in my-photos on the mobile against the names under the run's asset/ folder in the bucket.
- The remote database's own figures: psi summary for the run's folder, including "Files imported", which sync keeps up to date.
- Timing: the timestamps of the import and sync lines in the app's log, and the "Sync timings" lines for where sync's time went.

Things it never does

- It touches only photosphere-test-bucket-1.
- It never copies files off the mobile, except that /test:auto-import-sync:verify copies the my-photos replica into tmp/ so the local database can be verified. Everything else reads names, settings and logs with adb shell run-as.
- It never writes S3 credentials to a file or prints them. A command that needs them takes them from the vault for that one command.
- It does not use Consolidate into remote. That uploads the whole library from the mobile in one go, where this test lets syncing do it in the background.
