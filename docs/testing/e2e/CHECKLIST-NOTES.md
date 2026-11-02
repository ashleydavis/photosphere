# E2E Test Checklist Notes

Notes from manual test runs of [CHECKLIST.md](CHECKLIST.md). Headings and test names match the checklist.

Upcoming version: 0.0.9

## CLI

### General

- Most CLI tests kept their data in the one shared folder `/tmp/psi-test`, so two tests running at once deleted each other's databases. Every CLI test now uses its own folder, `/tmp/psi-cli-<group>-<test>`.
- `psi add` always reports `Total size: 0 Bytes`, and `psi list` shows `Size: Unknown` for every asset.

### Import

#### add-duplicate-content

- Failed at Test step 1: the output was expected to show both files processed. `add` reports `Files considered: 1` and `Already added: 0`, so the identical second file `b.png` is not counted at all. Steps 2 and 3 passed.

#### add-multiple-files

- The test said the zip holds copies of the directory's files. It holds two other files, `PXL_20260322_023611216.mp4` and `test-3.jpg`. Changed the expected counts from 3 to 5.

#### add-zip

- The test named files the zip does not hold. Changed the expected files to `PXL_20260322_023611216.mp4` and `test-3.jpg` and the counts from 3 to 2.
- Failed at Test step 2: `psi list` shows both assets under UUID names (such as `6e4286d9-….jpg`) with a temporary path under `/tmp/photosphere/.../file-scanner`, so the names inside the zip are lost on import. Steps 1 and 3 passed.

### Inspect

#### list-paging

- Failed at Test step 1: pages 1 to 3 and `Displayed 60 files total` were expected. Only `--- Page 1 ---` and `Displayed 20 files total` were printed, and step 2 counted 20 files, not 60.

### Verify

#### verify-full

- Failed at Test step 2: output showing that every file hash was checked was expected. `verify --full` prints the same as a quick verify. The Zig verify worker does not read the `full` option, and recomputes a hash only when a file's size or timestamp has changed.

### Move

#### move-file-between-databases

- Failed at Test step 1: `psi move` printed `error: unknown command 'move'`. The source still lists `test.jpg` and the destination is empty.

### Replication

#### replicate-deleted-asset

- Step 2 ran `ls` on the replica's `asset/` folder, which does not exist when the fixture's only asset is deleted, so it printed an `ls` error. It now runs `find` over the replica for the asset id, which checks the same thing across `asset/`, `display/` and `thumb/`.

#### replicate-partial-copy

- Failed at Test step 1: files were expected to be copied, and it reported `Total files copied: 0`. Step 2 then printed `No files found in the database.` where `test.jpg` was expected. Steps 3 and 4 passed.

#### replicate-unrelated-fails

- Passed. It prints a stray "An unknown error occurred" line before the real error.

### Databases (dbs)

#### edit-rename

- Step 2 checks the output no longer contains `edit-db`, but the seeded path ended in `/edit-db`, so it always did. Changed the seeded path to `/tmp/psi-cli-dbs-edit-rename/db`.

### Vault (keychain)

#### add-view-edit-delete

- Not run. Both keychain tests add and remove secrets with fixed names in the real OS keychain of the machine running them, so they were not run automatically.

### Origin

#### consolidate-unrelated-remote

- Passed. Step 2 printed `Failed to acquire write lock after 3 attempts`, apparently from a lock left by the step 1 sync that fails as expected, but it still pushed the file and exited 0.

### Info

#### info

- Failed at Test step 1: the EXIF date (27 May 2025) of `test/test.jpg` was expected and only the file modified date was shown. Step 2 shows `Photo date: 2025-05-27`, so the fixture carries it.
- Failed at Test step 3: a non-zero exit and a "not found" message were expected for `test/no-such-file.jpg`. It exited 0 and printed `Info for 0 item(s)`.

### Bug

#### bug

- Failed at Test step 1: `psi bug --no-browser --yes` printed `✓ Bug report opened in browser!` and neither the `issues/new` link nor any tool versions. `bug.zig` reads a `noBrowser` field, but the option parser handles `--no-browser` by setting `browser` to false, so the flag has no effect.

## Desktop

All desktop results below come from a test-hooks build of the app driven through its control connection on Linux, one isolated instance per test.

### General

- The "Import complete" toast never closes on its own (`duration: 0` in `main.tsx`), and it sits on top of later toasts, even after switching databases.
- The navbar badge says "1 photos", and the import toast for a video says "View photo".
- The Actions column on Manage Databases runs off the right edge of a 1200px window: the last icon is cut off and the Edit button is out of view.
- The About page gives the MCP URL as the fixed `localhost:3475`, but in test mode the server picks a free port (51375 in this run).
- Exporting `XDG_DATA_HOME` as the desktop tests' Prep says also moves mise's data folder. In the CLI terminal `mise exec` then installs the whole toolchain again into the test's `data` folder (one such download timed out and failed the Prep `zig build`), and `mise exec -- bun` can fail with "bun couldn't exec". Anyone whose tools come from mise hits this.
- The control connection answers `{"ok":true}` to a click on a `data-id` that does not exist. Only app.log records "element not found".
- After importing a directory, the gallery repeats month headings out of order (August 2026, October 2026, August 2026, October 2026).
- The "Import complete" toast covers the Replicate dialog's Start replication button.
- In the video viewer, the Quick Info panel overlaps the video's controls.

### Import

#### import-directory

- **revist and confirm** Problem importing from the zip file
    - Import files have uuid for file name and a wierd path.
    - No immediate need to fix this.
- Test step 1 did not say to enter a name, and Create stays disabled with "Name is required" until one is entered. Added a step that enters `source` to this test, import-files and import-video.

#### import-zip

- **revist and confirm** This will work but will have a similar problem as above.
- Failed at Check step 3: `psi list` was expected to show `PXL_20260322_023611216.mp4` and `test-3.jpg`, and it shows `<uuid>.mp4` and `<uuid>.jpg` under the path `/tmp/photosphere/<uuid>/file-scanner`. The names inside the zip are lost on import. Steps 1, 2 and 4 passed.

### Move

#### move-file-between-databases

- The asset was selected with `long-press`, not by hovering and clicking the circle the test describes: the circle shows only on hover and the control connection cannot hover. download-multiple-assets selected its assets the same way.

### Replication

#### replicate-partial-copy

- Failed at step 6: `psi list` on the replica says "No files found in the database", where `test.jpg` was expected. `psi verify` on the same replica passes with `Files imported: 1`. The CLI test of the same name fails the same way.

### Database

#### view-database-details

- The test expected an asset count in the View Database dialog, which has never had one (only Name, Description, Path, Origin and Linked Secrets). Removed the asset-count expectation from the test.

### Secrets

#### add-duplicate-name

- **revist and confirm** This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
- **revist and confirm** It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.
- Failed at Test step 2: no error appears in the UI and the dialog stays open. The error reaches only app.log: "Error: A secret named 'dup-secret' already exists." Step 3 passed: one `dup-secret` row, the vault holds one secret and Reveal shows the original values.
- Smoke test `15-duplicate-name` passes anyway, because it waits for that error in the log and never checks the UI.
- Rerun, failed at Test step 2: the app does refuse the duplicate (the vault still holds one `dup-secret` with the original values), but it shows no error, so the user is never told why Save did nothing.

#### add-api-key

- **revist and confirm** Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
- **revist and confirm** The should be a button that reveals the secret in the input while we are entering it.
- The view dialog shows `••••••••••` until **Reveal** is clicked, which the test did not say to do. Added that step to this test, add-encryption-key and add-s3-credentials.

#### view-secret

- Passed. "Add secret" with only a name filled in saves an `s3-credentials` secret with every field empty, and nothing checks for it.

### LAN Share

#### share-database

- **revist and confirm** When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.
- Step 5 did not say to click **Reveal**, which the view dialog needs before it shows the value. Added that step. With it, every step passed and the key matched.
- app.log has `[ERROR] Could not reach the database at …/sender/test-db` with `error:1E08010C:DECODER routines::unsupported`, caused by the test's made-up path and placeholder PEM.

### MCP

#### mcp-server

- The test said to turn MCP on and off and to list resources, but the app has no on/off control (the server starts with the app and stops when it quits) and the server offers tools only. Rewrote steps 2 and 4 to check the server starts and stops with the app, and step 3 to list the tools and call `get_media_file_info`. With that, every step passed.

## Mobile

### Automatic import

#### auto-import-new-remote

- **revist and confirm** *n* Step 6 fails: the import record doesn't load as new imports are added. The Import page reads the record once, when the database is opened, and never again, so a database opened before automatic import ran shows an empty list however many photos have gone in since.
- **revist and confirm** *n* Consolidate does not sound safe: it deletes all the local records, which sounds like losing the local database rather than consolidating it. It removes the local originals the remote already holds, then deletes `.db/bson` entirely, then replicates the remote down to replace them. The three are not one transaction, so anything that stops the app in that window leaves a phone with files deleted, no records, and no replacement. On a phone being killed mid-task is ordinary, and this work has no background service keeping it alive.
- **revist and confirm** *n* Replicate database just times out and produces an error, with fewer than 500 files in the database. The failure is "Operation timed out after 30000ms: () => copyAsset(...)": replicate wraps each asset copy in `retry`, whose per-attempt timeout defaults to thirty seconds, and one asset is an original, a display copy and a thumbnail. The S3 client was already given ten minutes per request for this reason, with a comment saying thirty seconds is far too short on a phone, but the replicate path still caps every copy at thirty.
- **revist and confirm** *n* A user who already has a remote database should be able to set up a new device by starting from it: the device gets a fresh partial copy of that database and imports into it, rather than building a separate library that then has to be joined to the remote. This is the second device case, and it is the normal one once somebody has more than one phone.
- **revist and confirm** *n* There should be one step in the UI that either creates the remote database and makes it the origin, or consolidates with a remote database that already exists. Today it takes a replicate and then a separate origin edit, because replication sets the origin on the copy and not on the database being replicated, and nothing says so.
- **revist and confirm** *n* Browse in the Replicate dialog does not browse. It comes up with an error instead of listing what is in the bucket, so the destination has to be typed by hand, which is how a path ends up wrong.
- **revist and confirm** *n* Replication needs to be a proper background task on mobile, so it keeps running when the app is not in the foreground. A first replication of a whole library is long, and it is the step that makes the remote copy exist.
- **revist and confirm** *n* An origin should use the credentials from the origin database's own entry. Right now the credentials have to be attached a second time to the database doing the syncing, so a database already in the list with working credentials cannot just be named as an origin.
- **revist and confirm** *n* Background sync probably needs to be incremental for a large database. A pass that works out the whole difference each time gets more expensive as the database grows, on a device that is paying for it in battery and data.
- **revist and confirm** *n* Setting the origin should let you pick from the databases already in the list, rather than making you type the path by hand. The path is usually one the app already knows.
- **revist and confirm** *n* The pairing code input when receiving a database should be numeric only, not the full alphabet keyboard. The code is digits.
- **revist and confirm** *n* There is no progress indicator showing that automatic import is happening. That would at least be one simple way to know something is still happening. Right now the only in-app signal is the gallery count, which moves only when a batch of 250 commits, so the app looks stopped for long stretches while it is working.
- **revist and confirm** *e* Android: works, but too slowly to call a pass. Steps 1 to 4 passed. Step 5: a photo taken at 07:06 did not appear until about 07:48, so 42 minutes instead of a few seconds.
- High priority
    - **revist and confirm** *e* A photo just taken must show up within 3 seconds. It took 42 minutes. New photos must take priority over importing the existing library: right now the import loop only looks for new photos between batches, and a batch of up to 60 old photos takes ten minutes or more, so a new photo is not even noticed until that finishes. The batch size must be much, much smaller than 60.
    - **revist and confirm** *e* Increase the number of workers on mobile to 10.
- Medium priority
    - **revist and confirm** *e* Hashing never hits the cache: 143 out of 143 hashes were computed from scratch. Each photo is copied out of the device library into a temp file before it is hashed, and the cache is keyed on the file path, size and last modified time, so a fresh copy never matches. The cache also lives in a temp directory that does not survive the app restarting. Find another way: read the original photo's path, timestamp and size from the device library and use those to know the file has already been imported, so it is never copied to temp or hashed again.
    - **revist and confirm** *e* Limit how many import child tasks run at once: 2 on mobile, 10 on desktop.
    - **revist and confirm** *e* The progress indicator stops while photos are still being imported, and so does the progress logging: both are fed by the same message. Progress is only reported twice per batch, once before the batch starts and once after it finishes, so with a batch of 60 there is no update at all for ten minutes or more. Report progress per photo.
    - **revist and confirm** *e* The new database took too long to show in the Open database list. Fix by reading the databases into memory before the dialog is opened.
- Low priority
    - **revist and confirm** *e* Automatic import must keep running at a low priority when the app is in the background, and when the screen is off. Right now nothing keeps it alive: there is no background service and no wake lock, so Android is free to freeze the work.
    - **revist and confirm** *e* Automatic import never says how many photos are left to import. Not knowing how much is still to come is no good, especially on a big library.
    - **revist and confirm** *e* Import the existing library newest first, not oldest first, so users see their recent photos quickly.
    - **revist and confirm** *e* Remove the lone file name shown under the counts on the automatic import card. It has no label and no explanation, and serves no good purpose.
    - **revist and confirm** *e* Split the Import page in two. One page for importing, where photos and videos are selected and added. A separate Import Log page that just shows what was recently imported. One page doing both jobs does not fit on a phone screen.
    - **revist and confirm** *e* The "My Photos" button in the Open database list is too small. Make it double the size and add padding underneath to separate it from the other buttons.
    - **revist and confirm** *e* The wording "a private photo database is created for you" needs updating. Check what it really does first.
    - **revist and confirm** *e* Better if turning the toggle on prompted to add a folder, after Allow is tapped.
- Android: step 6 fails. The Import page lists only the 2 photos imported from the existing library (test-1, test-2), both badged Automatic. The photo taken with the camera in step 5 is in the gallery (3 photos) but is not on the Import page, even after leaving the page and coming back. No import was running, so the count shown while one runs was not seen.
- Android: step 14 passed, but has some issues. `psi verify` passed (12 valid files, 0 invalid), and the originals of all 3 photos exported from the bucket are byte for byte the same as the photos on the phone. The counts do not line up: `psi verify` reports 12 files, `psi summary` reports 10 files and `Files imported: 0` (the phone's own copy reports 3), and the gallery shows 3 photos, so "the number of files matches what the gallery showed" cannot be checked as written. In the bucket the photos are named `35.jpeg`, `36.png` and `37.jpg` with the app's temp folder as their path, not their camera roll names and paths.
- Android: passed, with the problems noted above in steps 6 and 14. Run on Android only.

#### auto-import-existing-remote

- Android: fails at step 3. Starting the partial replication to `my-photos` shows "Replication failed: ReadOnlyFileSystem", raised from `replicateDatabase`. Steps 1 and 2 passed. The button is labelled **Start replication**, not **Replicate**.

#### auto-import-no-permission

- Android: fails at step 1. After **Don't allow**, the Automatic import toggle stays on and no message asks for the photo permission. No database is created. The notifications prompt still appears after the photo permission is refused.

#### auto-import-delete-after-backup

- Android: fails at step 1. Test fixed first: the app has no cleanup toggle, so steps 1 to 4 now use **Find photos already in my database** under **Free up space on this device**, which becomes **Delete N photo(s) from this device**. Pressing **Find photos already in my database** changes nothing on screen: the log has "Source cleanup counted", but the result reaches the page empty, so no count is shown and the button does not change.

### Import

#### import-photo-and-video

- Android: fails at step 1. The photo is imported and shows in the gallery, but its row on the Import page has no **manual** badge, and after **Clear** the page shows no import record. In step 2 the video imported with a thumbnail, but tapping it in the gallery crashed the emulator twice (once with a SEGV in the emulator process), so playback was not checked and steps 3 and 4 were not reached.

### Gallery

#### view-and-edit-asset

- Android: fails at step 2. Test fixed first: a tap opens a photo and press and hold selects it. The info panel shows the file name, width × height and date, but no file size and no camera details, although the fixture photos carry camera EXIF (the camera block in `asset-info.tsx` is commented out). Step 5: swiping does not move to the next photo; the on-screen arrows do. The edited description survived closing and reopening the database. Pinch zoom was not checked.

#### export-asset

- Android: passed. Test fixed first: Android shows the system save dialog, not the share sheet, and the full-photo check now compares against the stored file. Saved photo and video are byte for byte the same as the stored originals, and cancelling leaves nothing behind. Video playback was seen only in still screenshots.

### Download

#### download-assets

- Android: fails at step 2: no progress is shown for a multi-photo download. Step 4: there is no cancel control, and backing out of the folder picker returns with no message. Test fixed first: the full-photo check, and a step that downloads the same photos again so the same-name case happens. Same-name files are saved as `x.jpg (1)`, which Android does not recognise as an image.

### Database

#### create-and-open-database

- Android: fails at step 1. Choosing a new folder with **Browse** and pressing Create does nothing and shows no error; the dialog stays open. The log has `create-database task did not succeed: ReadOnlyFileSystem`: the folder picker gives a `content://` path the app cannot write to. Steps 2 to 5 could not run.

#### load-large-database

- Android: passed. Scrolling smoothness was not judged, only that every thumbnail loaded and the gallery stayed usable.

#### view-database-details

- Android: passed.

#### remove-recent-database

- Android: fails at step 3. The Prep's **New database** for `manual-test-2` hits the same `ReadOnlyFileSystem` failure as create-and-open-database, but the entry is still added to the list with a `content://` path, so typing an app-storage path is then refused with "A database named manual-test-2 already exists". Steps 1 and 2 passed. Step 3 cannot run because the removed database never existed on disk; step 4 was not run.

#### open-encrypted-database

- Android: passed. With the key deleted the message is "Could not reach the database: s3:…" while the log says "Encryption key not found in vault". The first delete of the key appeared to do nothing; the second showed a "Secret In Use" warning and worked.

#### edit-database-origin

- Android: fails at step 4. A made-up origin is skipped without telling anyone: the log has only an INFO line, "Sync skipped … origin not accessible", and nothing shows on screen. Steps 1 to 3 passed; the origin is set from **Edit**, the details sheet cannot set it. The quick sync after start-up did not run ("Sync debounce triggered" was logged, but nothing was queued until the 5-minute timer).

### Sync

#### sync-with-another-database

- Android: fails at step 5, which could not be run. Steps 1 to 4 passed. Step 5 (flight mode) cannot run on a pool emulator: turning flight mode on takes it off the network bridge and the pool monitor restarts it with its data wiped.

### Move

#### move-file-between-databases

- Android: fails at step 1. The move completes but the app shows no message that it did; only a log line is written. Steps 2 to 4 passed and `psi verify` found no failures on either database. Prep hits the `ReadOnlyFileSystem` failure when the target is chosen with **Browse**.

### Replication

#### replicate-to-another-database

- Android: fails at step 2. `psi verify` on the replica reports 51 asset record mismatches (`psi verify` on the source `test/dbs/50-assets` itself reports 10), while `psi compare` says the two are identical. Steps 1, 3 and 4 passed. Step 5 (network off) was not run: it cannot run on a pool emulator. The replication-complete message runs off the right edge of the screen.

#### partial-replica-and-prefetch

- Android: fails at step 4, which could not be run. Steps 1, 2, 3 and 5 passed. Step 4 (network off) cannot run on a pool emulator.

### S3

#### s3-database

- Android: fails at step 6. With a wrong secret key the app says "Could not reach the database" (log: `UnknownError`) rather than that it cannot authenticate. Steps 1 to 3 passed. Steps 4 and 5 (network off) were not run: they cannot run on a pool emulator. An S3 gallery listed May 2025 above October 2026.

### Secrets

#### add-and-view-secret

- Android: fails at step 4. Saving a second secret with an existing name is refused, but the dialog shows no message; the error only goes to the log (`secrets-page.tsx:475`). Every other step passed, including surviving a force-stop.

#### add-encryption-key

- Android: fails at step 4. A key whose text is not a PEM saves without complaint. Steps 1 to 3 passed.

#### add-s3-credentials

- Android: fails at step 3. With `manual-test-s3` attached through **Configure secrets…**, saving the edit fails with "Could not load credentials from any providers" (from `setDatabaseOrigin` in `edit-database-modal.tsx`) and the database does not open. Steps 1 and 2 passed.

### LAN Share

#### mobile-to-mobile

- Android: fails at step 4. Test fixed first: the sender shows the pairing code and the receiver types it, and Prep now gives each phone something to send (MinIO `mobile-test-m2m`). With a wrong code nothing is transferred, but both phones say only "No sender/receiver found within 60 seconds"; neither says a device is using a different code. Steps 1, 2 and 5 passed. Step 3 (network off) cannot run on a pool emulator.

#### desktop-to-mobile

- Android: passed. Test fixed first: the sender shows the pairing code, Prep now creates an encrypted database `desktop-share-enc` for the desktop to send, and step 3 attaches the key on the phone through **Configure secrets…**.

#### cli-to-mobile

- Android: fails at step 3, which could not be run. Test fixed first: the code is chosen and passed to `psi ... --code`, then typed on the phone. Steps 1, 2, 4 and 5 passed. Step 3 (network off) cannot run on a pool emulator. `psi secrets send` exits 0 after "Pairing code rejected", and a plain secret sent from the CLI shows as "API Key" on the phone.

### News

#### news-notifications

- Android: fails at step 1. No news is shown at start-up. The app logs `News check skipped: NameServerFailure`, though the device itself resolves `raw.githubusercontent.com` and the feed has an item. Steps 2 to 4 were not run.
