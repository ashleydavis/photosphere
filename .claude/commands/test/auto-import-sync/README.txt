Auto import and sync test

A test on a real Android phone of automatic import and background syncing to S3, from a phone with no Photosphere data to every photo on it being in the bucket. It measures how long import and sync take on a whole photo library and whether everything arrives, which no smoke test can do, since the smoke tests use a handful of fixture photos on emulators.

Commands

- /test:auto-import-sync:start (start.md): resets the last run and starts a new one. It shows what the reset deletes and asks twice before deleting anything.
- /test:auto-import-sync:check (check.md): reports whether import and sync are still going or have finished, with the counts, anything missing and how long each took. It only reads.

What it sets up

- The remote database: a folder named psi-test-<number> in the test bucket photosphere-test-bucket-1, holding one photo. Each run gets the next number, so a run never shares a folder with the one before it.
- The database entry: do-test, on this machine and on the phone. Its S3 credentials come from the vault secret default:s3.
- The local copy: a partial replica of do-test on the phone, named my-photos. It is the default database, so automatic import writes into it, and its origin is do-test, so syncing pushes what it imports to the bucket.
- The phone's settings: automatic import and syncing switched on, syncing only over Wi-Fi.

Running it

1. Plug the phone in over USB with debugging allowed, and put it on Wi-Fi.
2. Run /test:auto-import-sync:start. The reset uninstalls Photosphere from the phone, which deletes every database it holds there, and deletes the previous run's folder from the bucket. The phone's own photos are never touched, and the command checks the device's photo count is the same afterwards.
3. Leave the phone on Wi-Fi. It can be unplugged.
4. Run /test:auto-import-sync:check whenever you want to know where it is.

What the check compares

- Import: the device's photo and video count against what the last automatic import pass found already imported or failed to import.
- Sync: the names of the originals in my-photos on the phone against the names under the run's asset/ folder in the bucket.
- The remote database's own figures: psi summary for the run's folder, including "Files imported", which sync keeps up to date.
- Timing: the timestamps of the import and sync lines in the app's log, and the "Sync timings" lines for where sync's time went.

Things it never does

- It touches only photosphere-test-bucket-1.
- It never copies files off the phone. It reads names, settings and logs with adb shell run-as.
- It never writes S3 credentials to a file or prints them. A command that needs them takes them from the vault for that one command.
- It does not use Consolidate into remote. That uploads the whole library from the phone in one go, where this test lets syncing do it in the background.
