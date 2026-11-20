# E2E Test Checklist Notes

Notes from manual test runs of [CHECKLIST.md](CHECKLIST.md). Headings and test names match the checklist.

Upcoming version: 0.0.9

## CLI

### General

- Most CLI tests kept their data in the one shared folder `/tmp/psi-test`, so two tests running at once deleted each other's databases. Every CLI test now uses its own folder, `/tmp/psi-cli-<group>-<test>`.
- `psi add` always reports `Total size: 0 Bytes`, and `psi list` shows `Size: Unknown` for every asset.
- `psi list` on an S3 database filled by syncing from the Android app shows each mobile photo's `Path` as the app's temporary copy, `/data/user/0/au.com.codecapers.photosphere.ziggy/cache/.media-tmp`, rather than where the photo was on the mobile.

### Import

#### add-duplicate-content

- Failed at Test step 1: the output was expected to show both files processed. `add` reports `Files considered: 1` and `Already added: 0`, so the identical second file `b.png` is not counted at all. Steps 2 and 3 passed.
- Linux: passed. `add` now reports `Files considered: 2`, `Files added: 1`, `Already added: 1` and `Files failed: 0`; `summary` reports `Files imported: 1`, and `verify` passes with `Modified: 0` and `Removed: 0`. No errors in the errors logs.

#### add-multiple-files

- The test said the zip holds copies of the directory's files. It holds two other files, `PXL_20260322_023611216.mp4` and `test-3.jpg`. Changed the expected counts from 3 to 5.

#### add-zip

- The test named files the zip does not hold. Changed the expected files to `PXL_20260322_023611216.mp4` and `test-3.jpg` and the counts from 3 to 2.
- Failed at Test step 2: `psi list` shows both assets under UUID names (such as `6e4286d9-….jpg`) with a temporary path under `/tmp/photosphere/.../file-scanner`, so the names inside the zip are lost on import. Steps 1 and 3 passed.
- Linux rerun: failed at Check step 2 again. Prep and step 1 passed (`Files added: 2`, `Files failed: 0`). `psi list` showed the two assets as `b73ac4be-41d4-4754-a893-332f63fb927e.jpg` and `ef56064c-7e94-4e3e-a10d-99edeb08c614.mp4`, both with path `/tmp/photosphere/d33ad7da-f3f6-47e9-8587-602249037473/file-scanner`, not `PXL_20260322_023611216.mp4` and `test-3.jpg`. Step 3 was not run.
- Linux: passed. `psi list` now shows `test-3.jpg` and `PXL_20260322_023611216.mp4` under their own names, with the zip as their path, and `psi verify` reports `Files imported: 2` and `Modified: 0`. No errors in the errors logs.

### Inspect

#### database-summary

- `psi summary` on an S3 database filled by syncing from the Android app showed `Files imported: 1`, while the database held 2755 assets and `Total files` was 8138. The count comes from a counter that only imports into that database add to, and sync does not update it. `Total files` and `Total size` were right.

#### list-paging

- Failed at Test step 1: pages 1 to 3 and `Displayed 60 files total` were expected. Only `--- Page 1 ---` and `Displayed 20 files total` were printed, and step 2 counted 20 files, not 60.
- Linux: failed again at Test step 1. The prep summary showed `Files imported: 60`. `psi list --page-size 20` printed only `--- Page 1 ---` with 20 files, then `End of results. Displayed 20 files total.` and exited 0. No errors or warnings in the errors logs.
- Linux: passed after `psi list` was fixed to show the rest of a sort index page as further pages, and the test's expected count was changed to the number of assets (50).

### Verify

#### verify-full

- Failed at Test step 2: output showing that every file hash was checked was expected. `verify --full` prints the same as a quick verify. The Zig verify worker does not read the `full` option, and recomputes a hash only when a file's size or timestamp has changed.
- Linux: failed again at Test step 2. `psi verify --full` printed exactly the same output as the quick verify in step 1 (`Unmodified: 4`, `Modified: 0`, `New: 0`, `Removed: 0`, `Database verification passed - all files are intact`), with nothing to show that file hashes were checked. No errors in the errors logs.
- Linux: passed after the verify worker was changed to hash every file when `--full` is set, and the test was changed to prove the full check by what it finds: step 3 changes the asset's content but keeps its size and modification time, the quick verify in step 4 reports `Modified: 0` and the full verify in step 5 reports `Modified: 1` naming the asset. No errors in the errors logs.

### Move

#### move-file-between-databases

- Failed at Test step 1: `psi move` printed `error: unknown command 'move'`. The source still lists `test.jpg` and the destination is empty.
- Linux: failed again at Test step 1. `psi move test/test.jpg --db ... --dest ...` printed `error: unknown command 'move'` and `(Did you mean remove?)`, and exited 1. `psi help` lists no `move` command.
- The `psi move` command is not yet implemented.
- Passed with notes: the test cannot run until `psi move` is implemented.

### Replication

#### replicate-deleted-asset

- Step 2 ran `ls` on the replica's `asset/` folder, which does not exist when the fixture's only asset is deleted, so it printed an `ls` error. It now runs `find` over the replica for the asset id, which checks the same thing across `asset/`, `display/` and `thumb/`.

#### replicate-partial-copy

- Failed at Test step 1: files were expected to be copied, and it reported `Total files copied: 0`. Step 2 then printed `No files found in the database.` where `test.jpg` was expected. Steps 3 and 4 passed.
- Linux: failed again at Test step 1. The partial replicate reported `Total files copied: 0` and `Total records copied: 0`, then `✅ Replication completed successfully`. Step 2 printed `No files found in the database.` where `test.jpg` was expected. No errors in the errors logs.
- `psi list` needs work for partial databases: it should show the real file list even when no files were replicated, but it reads only the local disk, where a partial replica holds no records.
- A partial replica copying 0 files and 0 records is intended: the files are fetched lazily. The "files copied" expectation in step 1 does not hold for a partial replica.
- Linux: passed with the `psi list` problem above. Steps 3 and 4 passed: `psi verify` on the replica passed with `Files imported: 1` and 0 failures, and `psi origin` showed the source path. No errors in the errors logs.

#### replicate-unrelated-fails

- Passed. It prints a stray "An unknown error occurred" line before the real error.

### Databases (dbs)

#### edit-rename

- Step 2 checks the output no longer contains `edit-db`, but the seeded path ended in `/edit-db`, so it always did. Changed the seeded path to `/tmp/psi-cli-dbs-edit-rename/db`.

### Vault (keychain)

#### add-view-edit-delete

- Not run. Both keychain tests add and remove secrets with fixed names in the real OS keychain of the machine running them, so they were not run automatically.
- Linux: both keychain tests passed against the real OS keychain, and every test secret was removed at the end. Both test files were laid out as Prep, Test and Check first, with every command, expectation and step order kept.

### Origin

#### consolidate-unrelated-remote

- Passed. Step 2 printed `Failed to acquire write lock after 3 attempts`, apparently from a lock left by the step 1 sync that fails as expected, but it still pushed the file and exited 0.
- Linux: passed again, with the same `[WARN] Failed to acquire write lock after 3 attempts` in step 2. The lock was held "since 3s ago", taken by the step 1 sync that failed.

### Info

#### info

- Failed at Test step 1: the EXIF date (27 May 2025) of `test/test.jpg` was expected and only the file modified date was shown. Step 2 shows `Photo date: 2025-05-27`, so the fixture carries it.
- Failed at Test step 3: a non-zero exit and a "not found" message were expected for `test/no-such-file.jpg`. It exited 0 and printed `Info for 0 item(s)`.
- Linux: failed again at Test step 1. `psi info test/test.jpg --yes` showed `Type: image/jpeg` and `Dimensions: 2560 × 1920` but no EXIF date (27 May 2025): only `Modified: 8/5/2026, 9:38:12 AM`. No errors in the errors log.
- Linux: passed after `psi info` was changed to show the date a file was taken, read from its EXIF, and to report a path that does not exist as `Error: File not found` with exit code 1. Step 1 showed `Photo date: 5/27/2025, 9:54:16 AM`, and step 3 exited 1. No errors in the errors logs.

### Bug

#### bug

- Failed at Test step 1: `psi bug --no-browser --yes` printed `✓ Bug report opened in browser!` and neither the `issues/new` link nor any tool versions. `bug.zig` reads a `noBrowser` field, but the option parser handles `--no-browser` by setting `browser` to false, so the flag has no effect.
- Linux: failed again at Test step 1. `psi bug --no-browser --yes` printed `✓ Bug report opened in browser!` and opened the browser, showed the system and psi version but no tool versions, and printed no `issues/new` link. It exited 0. The comment above the bug command in `apps/cli-zig/index.zig` says `noBrowser` is never set.
- Linux: passed after the bug command was changed to read the `browser` option commander stores for `--no-browser`, without the `false` default that kept it false. No browser opened, it printed the `issues/new` URL and exited 0. The printed summary now has a `Tools:` line with the ImageMagick, ffmpeg and ffprobe versions, beside the system and the psi version. No errors in the errors logs.

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

- Test step 1 did not say to enter a name, and Create stays disabled with "Name is required" until one is entered. Added a step that enters `source` to this test, import-files and import-video.

#### import-zip

- Failed at Check step 3: `psi list` was expected to show `PXL_20260322_023611216.mp4` and `test-3.jpg`, and it shows `<uuid>.mp4` and `<uuid>.jpg` under the path `/tmp/photosphere/<uuid>/file-scanner`. The names inside the zip are lost on import. Steps 1, 2 and 4 passed.
- Linux: passed. `psi list` shows `test-3.jpg` and `PXL_20260322_023611216.mp4` under the path of `test-archive.zip`, and `psi verify` passes with `Files imported: 2`.

### Move

#### move-file-between-databases

- The asset was selected with `long-press`, not by hovering and clicking the circle the test describes: the circle shows only on hover and the control connection cannot hover. download-multiple-assets selected its assets the same way.
- Linux: passed. After **Move to dest** the source gallery is empty but the navbar still says "1 selected".

### Replication

#### replicate-partial-copy

- Failed at step 6: `psi list` on the replica says "No files found in the database", where `test.jpg` was expected. `psi verify` on the same replica passes with `Files imported: 1`. The CLI test of the same name fails the same way.
- Linux: passed with a known issue. `psi list` on a partial replica printed "No files found in the database." where `test.jpg` was expected, because `psi list` reads only the local disk, where a partial replica holds no records. That is a `psi list` problem, not a failure of this test. Steps 1 to 5, 7 and 8 passed: `psi verify` on the replica passed with `Files imported: 1` and `psi origin` printed the source path. No new lines in the errors logs.

### Database

#### view-database-details

- The test expected an asset count in the View Database dialog, which has never had one (only Name, Description, Path, Origin and Linked Secrets). Removed the asset-count expectation from the test.

### Secrets

#### add-duplicate-name

- This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
- It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.
- Failed at Test step 2: no error appears in the UI and the dialog stays open. The error reaches only app.log: "Error: A secret named 'dup-secret' already exists." Step 3 passed: one `dup-secret` row, the vault holds one secret and Reveal shows the original values.
- Smoke test `15-duplicate-name` passes anyway, because it waits for that error in the log and never checks the UI.
- Rerun, failed at Test step 2: the app does refuse the duplicate (the vault still holds one `dup-secret` with the original values), but it shows no error, so the user is never told why Save did nothing.
- Linux, rerun: failed at Test step 2 again. After Save on the second `dup-secret`, the Add Secret dialog stays open with no error in it and no toast. The error reaches only the errors log, word for word: `[ERROR] [Frontend] Save error:` / `Error: A secret named 'dup-secret' already exists.` / `addSecret@ziggy-app://app/assets/index-Dx0kBPy-.js:55360:22`. `handleSave` in `secrets-page.tsx` is still caught by `log.exception('Save error:', ...)` and nothing else. Step 1 passed. Step 3 was not run.
- Linux, rerun: passed with a note. Step 1 added `dup-secret`. Step 2: the duplicate was refused, but the error again reached only the log (`[ERROR] [Frontend] Save error:` / `Error: A secret named 'dup-secret' already exists.`), not the screen; that is the known issue of errors shown only in the log, so it does not fail the test. Step 3: the vault holds one `dup-secret` with the values from step 1.

#### add-api-key

- Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
- The should be a button that reveals the secret in the input while we are entering it.
- The view dialog shows `••••••••••` until **Reveal** is clicked, which the test did not say to do. Added that step to this test, add-encryption-key and add-s3-credentials.

#### view-secret

- Passed. "Add secret" with only a name filled in saves an `s3-credentials` secret with every field empty, and nothing checks for it.

### LAN Share

#### share-database

- When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.
- Step 5 did not say to click **Reveal**, which the view dialog needs before it shows the value. Added that step. With it, every step passed and the key matched.
- app.log has `[ERROR] Could not reach the database at …/sender/test-db` with `error:1E08010C:DECODER routines::unsupported`, caused by the test's made-up path and placeholder PEM.
- Linux, rerun: passed with a real RSA key generated by `openssl genpkey` as the seeded value. Adding `test-db` at its made-up path shows a warning toast "Database not found: /tmp/psi-desktop-share-database/sender/test-db" and logs nothing to the errors log. The Add Database dialog closed. The receiver's revealed PEM matches the sender's, and the two vault entries hash the same.

### MCP

#### mcp-server

- The test said to turn MCP on and off and to list resources, but the app has no on/off control (the server starts with the app and stops when it quits) and the server offers tools only. Rewrote steps 2 and 4 to check the server starts and stops with the app, and step 3 to list the tools and call `get_media_file_info`. With that, every step passed.

## Mobile

### General

Known issues. Each is noted under the tests it shows up in, and none of them fails a test:

- The Import page does not list imports made since the database was opened.
- The app shows the database id nowhere.
- **Find photos already in my database** shows no count.
- The app reloads the gallery from the top when it comes back from the background.
- An error or a result that is only logged and never shown on screen.

### Automatic import

#### auto-import-new-remote

- *n* Step 6 fails: the import record doesn't load as new imports are added. The Import page reads the record once, when the database is opened, and never again, so a database opened before automatic import ran shows an empty list however many photos have gone in since.
- *n* Consolidate does not sound safe: it deletes all the local records, which sounds like losing the local database rather than consolidating it. It removes the local originals the remote already holds, then deletes `.db/bson` entirely, then replicates the remote down to replace them. The three are not one transaction, so anything that stops the app in that window leaves a mobile with files deleted, no records, and no replacement. On a mobile being killed mid-task is ordinary, and this work has no background service keeping it alive.
- *n* A user who already has a remote database should be able to set up a new device by starting from it: the device gets a fresh partial copy of that database and imports into it, rather than building a separate library that then has to be joined to the remote. This is the second device case, and it is the normal one once somebody has more than one mobile.
- *n* There should be one step in the UI that either creates the remote database and makes it the origin, or consolidates with a remote database that already exists. Today it takes a replicate and then a separate origin edit, because replication sets the origin on the copy and not on the database being replicated, and nothing says so.
- *n* Replication needs to be a proper background task on mobile, so it keeps running when the app is not in the foreground. A first replication of a whole library is long, and it is the step that makes the remote copy exist.
- *n* Background sync probably needs to be incremental for a large database. A pass that works out the whole difference each time gets more expensive as the database grows, on a device that is paying for it in battery and data.
- *n* The pairing code input when receiving a database should be numeric only, not the full alphabet keyboard. The code is digits.
- *e* Android: works, but too slowly to call a pass. Steps 1 to 4 passed. Step 5: a photo taken at 07:06 did not appear until about 07:48, so 42 minutes instead of a few seconds.
- High priority
    - *e* A photo just taken must show up within 3 seconds. It took 42 minutes. New photos must take priority over importing the existing library: right now the import loop only looks for new photos between batches, and a batch of up to 60 old photos takes ten minutes or more, so a new photo is not even noticed until that finishes. The batch size must be much, much smaller than 60.
    - *e* Increase the number of workers on mobile to 10.
- Low priority
    - *e* Automatic import never says how many photos are left to import. Not knowing how much is still to come is no good, especially on a big library.
    - *e* Split the Import page in two. One page for importing, where photos and videos are selected and added. A separate Import Log page that just shows what was recently imported. One page doing both jobs does not fit on a mobile screen.
    - *e* The "My Photos" button in the Open database list is too small. Make it double the size and add padding underneath to separate it from the other buttons.
    - *e* The wording "a private photo database is created for you" needs updating. Check what it really does first.
    - *e* Better if turning the toggle on prompted to add a folder, after Allow is tapped.
- Android: step 6 fails. The Import page lists only the 2 photos imported from the existing library (test-1, test-2), both badged Automatic. The photo taken with the camera in step 5 is in the gallery (3 photos) but is not on the Import page, even after leaving the page and coming back. No import was running, so the count shown while one runs was not seen.
- Android: step 14 passed, but has some issues. `psi verify` passed (12 valid files, 0 invalid), and the originals of all 3 photos exported from the bucket are byte for byte the same as the photos on the mobile. The counts do not line up: `psi verify` reports 12 files, `psi summary` reports 10 files and `Files imported: 0` (the mobile's own copy reports 3), and the gallery shows 3 photos, so "the number of files matches what the gallery showed" cannot be checked as written. In the bucket the photos are named `35.jpeg`, `36.png` and `37.jpg` with the app's temp folder as their path, not their camera roll names and paths.
- Android: passed, with the problems noted above in steps 6 and 14. Run on Android only.
- Android: steps 1 to 5 passed; the photo taken in step 5 was in the gallery within 15 seconds. Step 6: the Import page listed no imported photos, only an "Import" card reading "Imported 0, Already there 17" and the empty "Import photos / Select photos" prompt. This is a known issue, not a fail for this test: the Import page does not show automatic imports until the app restarts.
- Android: fails at step 9. Steps 1 to 8 passed on a rerun from Prep (step 7 listed the imports after the restart; step 8 Route A saved the S3 secret). Step 9 cannot be run: it needs the mobile's database id, and the app shows it nowhere. The database's View details sheet shows name, description, path, origin and linked secrets, and the database summary (the photo count button) shows counts, path, storage type, mode and full hash, but neither has the id.
- The missing database id is a known issue and not a fail. The test is left untested: steps 9 to 16 still need running, and step 9 needs the id read some other way.
- Android rerun: fails at step 12. Steps 1 to 11 passed. The database id was read from a copy of `files/dbs/photosphere-default` with `psi database-id`, and the remote was created with it. The origin was typed into **Origin** (`s3:photosphere-smoke-test/auto-sync-test`), saved, and shown in **View details** with S3 credentials `My Photos`. With syncing on, the first pass failed: `[ERROR] [Worker 3] Sync failed for "/data/user/0/au.com.codecapers.photosphere.ziggy/files/dbs/photosphere-default"` / `Error: Failed to check if file exists: Could not load credentials from any providers: Could not load credentials from any providers` / `Caused by:` / `CredentialsProviderError: Could not load credentials from any providers`. `psi summary` on the remote still reports 0 files imported. Steps 13 to 16 were not run.
- Android: passed, after step 8 was changed to receive the bucket with `psi dbs send` (so the bucket has its own database-list entry with its credentials) and step 10 to pick it from **Choose…**. The step 12 failure above came from step 8 Route A, which gave the bucket no entry, so the origin had no credentials; Route A has been removed. Every step went as expected: 23 library photos imported, the camera photo in the gallery 7 seconds after returning, the first sync pass merged 24 records into the bucket, a photo taken with import off was not imported, `psi verify` on the bucket passed with 24 files imported matching the gallery, and after import was switched back on a new photo was in the gallery in 6 seconds and the bucket held 26, the same as the gallery. Step 6 showed the known Import page issue. No errors log lines. Run on Android only.

#### auto-import-existing-remote

- Android: fails at step 3. Starting the partial replication to `my-photos` shows "Replication failed: ReadOnlyFileSystem", raised from `replicateDatabase`. Steps 1 and 2 passed. The button is labelled **Start replication**, not **Replicate**.
- Android rerun: fails at step 3 again, the same way. The log has two `[WARN] [Worker 3] An operation failed. Retrying after: ReadOnlyFileSystem` lines, then `[ERROR] [Frontend] Replication error: Error: ReadOnlyFileSystem at replicateDatabase`. Prep and steps 1 and 2 passed. The first attempt at this rerun was lost part way through, when the pool monitor restarted the emulator with its data wiped.
- There should be a "default" label on the entry for the database that we can check is there.
- Sorting is broken for newly imported items.
- Sorting comes good when reopening or maybe when refreshing the database.
- Android: step 10, the Import page lists the 2 fixture photos badged Automatic but not the photo taken with the camera in step 9, though it is in the gallery and in the bucket. The database was last opened after the fixtures were imported and before the camera photo, which fits the Import page reading the record only when the database is opened. Each row shows the app's temp-folder path rather than the photo's name. Not counted as a failure of this test.
- Android: passed, run on Android only. Every step went as expected after the shard cache fix and with the `50-assets` fixture down to 50 photos, each with a record: the camera photo was imported 10 seconds after it was taken, the bucket went from 50 to 53 photos after a sync pass, and `psi verify` on the bucket passed with 0 record mismatches. Step 10 showed the same empty Import page as above, because the database was opened before the imports ran; after the restart in step 11 all 3 imports were listed.
- Android: fails at step 12. Steps 1 to 11 went as expected (step 10's empty Import page is the known issue): the replica showed 50 photos, automatic import added the device's 11, the camera photo was in the gallery within 30 seconds, and after a sync pass the bucket went from 60 to 72 files imported. `psi verify` passed (185 files unmodified, 104 database files valid, 0 invalid), but its 72 files do not match the 62 photos the gallery shows. The `50-assets` bucket already reported 60 files imported for its 50 photos in Prep.
- Android rerun: passed. With the `50-assets` fixture's count corrected to 50, the bucket started at 50 files imported; the device's photos took the gallery to 67, a camera photo was in it 14 seconds later (68), the next sync pass took the bucket to 68, and `psi verify` on the bucket passed with 68 files imported, matching the gallery. No errors log lines.

#### auto-import-no-permission

- Android: fails at step 1. After **Don't allow**, the Automatic import toggle stays on and no message asks for the photo permission. No database is created. The notifications prompt still appears after the photo permission is refused.
- Android rerun: fails at step 1 again, the same way. The setting is switched off underneath (`config.toml` has `auto_import: enabled: false`, and the log has "Automatic import switched off: Photosphere needs permission to read your photos before it can import them automatically. Grant photo access in your device settings, under Apps, Photosphere, Permissions."), but the screen still shows the toggle on, also after closing and reopening Configuration, and the message is never shown. Steps 2 and 3 were not run.
- Android, third run: fails at step 1 the same way. After **Don't allow** the toggle still shows on several seconds later and no message appears, while `config.toml` has `[auto_import] enabled = false`. No database was created (no `dbs` folder). No new errors log lines. Steps 2 and 3 were not run.
- The toggle and the missing message are the known on-screen issue and not a fail. The test is left untested: steps 2 and 3 still need running.
- Android: passed. Step 1: after **Don't allow** the setting switched itself off (`enabled = false`) and no database was created; the toggle still showed on with no message (known on-screen issue), so the next tap turned it off and a second tap on. Step 2: with the permission granted, the toggle stayed on, `photosphere-default` was created and the import started. Step 3: revoking the permission made Android end the app; reopened, it asked for the permission again, and on **Don't allow** logged "Automatic import switched off: Photosphere needs permission to read your photos…" and stopped the import. No crash and no errors log lines.

#### auto-import-delete-after-backup

- Android: fails at step 1. Test fixed first: the app has no cleanup toggle, so steps 1 to 4 now use **Find photos already in my database** under **Free up space on this device**, which becomes **Delete N photo(s) from this device**. Pressing **Find photos already in my database** changes nothing on screen: the log has "Source cleanup counted", but the result reaches the page empty, so no count is shown and the button does not change.
- Android rerun: fails at step 1 the same way. Pressed twice, with 21 photos in the gallery: each press logs "Source cleanup counted", but no message appears and the button still reads **Find photos already in my database**. No new errors log lines. Steps 2 to 5 were not run.
- The missing count is a known issue and not a fail. The test is left untested: steps 2 to 5 still need running, and they need the delete button the count leads to.
- Android rerun: still blocked at step 1 by the known issue. With 27 photos imported, **Find photos already in my database** logged "Source cleanup counted" but showed no count and the button stayed the same, so the **Delete N photo(s)** button steps 2 to 5 need never appears. Left untested. No errors log lines.
- Android rerun: still blocked at step 1 by the known issue. Prep passed (40 items found, 28 photos in the gallery, 0 failed). **Find photos already in my database** logged "Source cleanup counted" and a pass over the 40 items, all already there, but showed no count and the button stayed the same. Steps 2 to 5 were not run. Left untested. No errors log lines.
- Android rerun: the same again. Prep passed (28 imported, 0 failed); **Find photos already in my database** logged "Source cleanup counted" but showed no count and the button stayed the same. Steps 2 to 5 were not run. Left untested.
- Android rerun after two fixes (cleanup with no sources now looks where automatic import does; the Android delete asks with media uris): passed, steps 1 to 5. Step 1: "41 of the 41 photo(s) on this device are in your database and can be deleted." and **Delete 41 photo(s) from this device**. Step 2: the system asked "Allow Photosphere to delete 41 items?", Allow deleted them all (the library had no images or videos left) and the gallery still showed 28 photos. Step 3: Deny left `test-2.png` in the library, the page said "1 could not be deleted", and it did not ask again. Step 4: `not-an-image.jpg` failed to import, Find offered 1 of 2, and after Allow only `test-2.png` was gone; the gallery had no broken entry. Step 5: the database copied off the device with `adb run-as` passed `psi verify`, 28 files imported. The count stays on the button until the app restarts, so a photo added after a count needs the app restarted before Find counts it.
- Android rerun: passed, steps 1 to 5. 4 photos imported in prep; step 1 offered 4 of 4; step 2 (after `test-1.jpeg`) asked to delete 5 items and Allow left the library empty with the gallery at 5 photos; step 3 Deny kept `test-2.png` with no second prompt; step 4 offered 1 of 2 and kept `not-an-image.jpg`; step 5 `psi verify` passed on the database copied off the device, 6 files imported (every deleted photo).

### Import

#### import-photo-and-video

- Android: fails at step 1. The photo is imported and shows in the gallery, but its row on the Import page has no **manual** badge, and after **Clear** the page shows no import record. In step 2 the video imported with a thumbnail, but tapping it in the gallery crashed the emulator twice (once with a SEGV in the emulator process), so playback was not checked and steps 3 and 4 were not reached.
- Android rerun: passed. Step 4's empty Import page is the known Import page issue, which is not a fail for this test. Steps 1 to 3 passed: the photo imported ("1 added") and was listed, the video imported with a thumbnail, opened without a crash and played (its picture changed between frames), and importing the photo again reported "Already there 1" with the gallery still at 2. At step 4, after the import result is closed, the Import page lists neither import, only the empty "Import photos / Select photos" prompt. Each import's result screen lists only that one file, and closing it leaves no record on the page. No new errors log lines.
- Android rerun: fails at step 2. Prep and step 1 passed (the **manual** badge is no longer required). The video imports and shows in the gallery with a thumbnail, but tapping it takes the whole emulator down within 2 seconds, twice more this run (adb "error: closed", then the device is gone). The emulator log has repeated "ERROR | Failed to find ColorBuffer: <n>" and "bad color buffer handle <n>", and just before the last crash "Created VkInstance", "Destroyed VkInstance" then "ERROR | Failed to find ColorBuffer: 543". Playback was not seen; steps 3 and 4 were not run.
- Known problem to be fixed later.
- Android: passed, run on Android only. The video played and the emulator did not crash. Step 3 showed "Already there 1" on the card while the summary under it said "0 skipped" and listed no row. Step 4 listed no imports, the known problem above.

### Gallery

#### view-and-edit-asset

- Android: fails at step 2. Test fixed first: a tap opens a photo and press and hold selects it. The info panel shows the file name, width × height and date, but no file size and no camera details, although the fixture photos carry camera EXIF (the camera block in `asset-info.tsx` is commented out). Step 5: swiping does not move to the next photo; the on-screen arrows do. The edited description survived closing and reopening the database. Pinch zoom was not checked.
- Android rerun: stopped at step 1. `adb shell input tap` on a gallery thumbnail does not open the photo (three tries, including a 100 ms touch) and nothing is logged, while an adb tap on the menu button works. A finger tap on a thumbnail opens it ("AssetView opened"). Pan and zoom were not checked; steps 2 to 5 were not run.
- Zooming doesn't work. Confirmed on emulator, not real device.
- These details should be fixed later. Not important right now.
- We'll fix this later.
- Swipe can be fixed later.
- Android: passed, run on Android only. An adb tap opened the photo. The edited description survived reopening the database through **Open database** (a **Close database** item exists in the ⋮ menu; the side menu has none). The on-screen arrows move to the next and previous photo and Quick Info follows. Zoom, file size and swipe are the problems noted above. A first attempt was lost part way through step 5 when an Android smoke run took over the emulator and reinstalled the app.
- Android rerun: fails at step 4. Steps 1 to 3 went as expected (the photo opened; the info panel showed the file name `a5C4QyqXH7I.jpg`, 2555 × 3832, Feb 18, 2023 and "No location"; the description field took the typed text and closing the panel and photo showed no error). After **Close database** and reopening `test-50-assets` from Recent databases, the same photo's description is back to "a man standing in front of a body of water": the typed "WALKTHROUGH-EDIT-1119" is gone. The database was closed a few seconds after the panel was closed. No new errors log lines. Step 5 was not run.
- Android rerun: fails at step 4 again, and the edit is not lost: it is shown stale. After typing " WALKTHROUGH-EDIT-2" into the description, closing the panel and the photo, waiting five seconds, **Close database** and reopening `test-50-assets` from Recent databases, the info panel of the same photo shows "a man standing in front of a body of water" without the edit. The record in the device's database (`files/50-assets`, read with `psi debug record --all`) holds "a man standing in front of a body of water WALKTHROUGH-EDIT-2", so the edit was saved and the reopened database shows an old copy of the record. No errors log lines.
- The two failures above were not a stale record: the description field was one line high, so an edit that wrapped onto a second line was hidden. Fixed by letting the field grow.
- Android rerun after the fix: passed. After **Close database** and reopening `test-50-assets`, the description shows "a man standing in front of a body of water" and "WALKTHROUGH" on a second line. The on-screen arrows move between photos and Quick Info follows. No errors log lines. Zoom was not checked; file size, camera details and swipe are the problems noted above.

#### export-asset

- Android: passed. Test fixed first: Android shows the system save dialog, not the share sheet, and the full-photo check now compares against the stored file. Saved photo and video are byte for byte the same as the stored originals, and cancelling leaves nothing behind. Video playback was seen only in still screenshots.
- Android rerun: passed. The saved photo is the stored original byte for byte (400 × 241), dismissing the save dialog returned to the photo with no error and no new file, and the saved video is byte for byte `test/multiple-files/test.mp4` and played in Google Photos (its picture changed between frames).

### Download

#### download-assets

- Android: fails at step 2: no progress is shown for a multi-photo download. Step 4: there is no cancel control, and backing out of the folder picker returns with no message. Test fixed first: the full-photo check, and a step that downloads the same photos again so the same-name case happens. Same-name files are saved as `x.jpg (1)`, which Android does not recognise as an image.
- Android rerun: fails at step 2 again. Prep and step 1 passed: the single download saved `L0Bte153mM8.jpg` to `Download/`, byte for byte the same as the stored original, and it is in the device's media store. Downloading 3 selected photos to `Pictures` saved all 3 in under a second with only a "Downloaded 3 assets" toast at the end: no progress was shown, and `downloadAssets` in `asset-database-source.tsx` reports none. The repeat download into the same folder (rest of step 2) and steps 3 and 4 were not run.
- Should show progress of downloads, that's not a reason to fail this test.
- Android rerun continued: step 2 passed otherwise. All 3 photos arrived, and downloading them again into `Pictures` put copies beside them named `x.jpg (1)`, which the media store lists as `application/octet-stream`, not images. Step 3 passed: `test.mp4` saved, byte for byte the same as the source, and played in Google Photos. Fails at step 4: downloading 9 selected photos finished in under a second with no cancel control on screen at any point, and the multi-download code (`downloadAssets` and `saveDownloadedFiles` in `platform-provider-ziggy.tsx`) has no cancel. All 9 were saved (duplicates as `x.jpg (2)`).
- Android rerun: fails at step 3. Step 1 passed: `a5C4QyqXH7I.jpg` saved byte for byte the same as the stored original (400 × 600) and listed in the media store as `image/jpeg`. Step 2 passed apart from progress: 4 selected items (3 photos and the video) all arrived with only a "Downloaded 4 assets" toast, and downloading them again put copies beside them as `x.jpg (1)` and `x.jpg (2)` rather than overwriting. Step 3: downloading the video alone saved it as `test.mp4 (3)`, because `test.mp4` and its earlier copies were already in the folder. The file is byte for byte the source, but the media store lists it as `application/octet-stream`, and opening it as a video does not play it, so it does not play back from the device. Step 4 was not run. No new errors log lines.
- Android rerun: fails at step 4. The step 3 failure above came from earlier runs' copies left in `Pictures/manual-test` (and the video having been selected in step 2), so the folder was emptied first. Step 1 passed (byte for byte the stored original, `image/jpeg`). Step 2 passed: 3 photos arrived each time and the repeat download put `(1)` and `(2)` copies beside them; progress is not shown, which is not a fail. Step 3 passed: the video saved as `test.mp4`, byte for byte the source, listed as `video/mp4`, and played in Google Photos. Step 4: downloading 7 photos finished within a second with only a "Downloaded 7 assets" toast, and there is no control to cancel a download in progress (`downloadAssets` in `asset-database-source.tsx` treats only a cancelled folder picker as cancelled). No errors log lines.
- Playing the downloaded video was taken out of the mobile test. Playback is checked only on desktop platforms, and only when the platform supports the video's format.
- Android rerun: fails at step 4 again. Prep passed (`test.mp4` imported, 51 items). Step 1 passed: `b2873V_RcEw.jpg` saved, byte for byte the stored original, listed as `image/jpeg`. Step 2 passed: 3 photos arrived each time and the repeat download put further `(n)` copies beside them, without overwriting. Step 3 passed: the video saved as `test.mp4 (1)` beside older copies, byte for byte the imported `test.mp4`. Step 4: 7 photos downloaded within a second with only a "Downloaded 7 assets" toast, and no cancel control appeared. No errors log lines.
- Passed on Android, with a note: there is no way to cancel a download in progress (step 4).

### Database

#### create-and-open-database

- Android: fails at step 1. Choosing a new folder with **Browse** and pressing Create does nothing and shows no error; the dialog stays open. The log has `create-database task did not succeed: ReadOnlyFileSystem`: the folder picker gives a `content://` path the app cannot write to. Steps 2 to 5 could not run.
- Android rerun: fails at step 1 again, the same way. Prep passed. Name `manual-test`; **Create** stays disabled until a path is set, and the test does not say which path to use, so a new folder `Pictures/manual-test` was made in the **Browse** picker and allowed. The path became `content://com.android.external…`. Create showed nothing and the dialog stayed open. Errors log: `[ERROR] [Frontend] Create database error: Error: create-database task did not succeed: ReadOnlyFileSystem at createDatabaseAtPath`, after two `[WARN] [Worker 2] An operation failed. Retrying after: ReadOnlyFileSystem`.
- Android rerun: passed. The New Database dialog now takes a typed path with no **Browse**; name and path `manual-test` created and opened an empty database. `test.jpg` imported and showed in the gallery, reopening `manual-test` from **Open database** and restarting the app both kept it, and the summary showed 1 photo, matching the gallery. No new errors log lines.

#### load-large-database

- Android: passed. Scrolling smoothness was not judged, only that every thumbnail loaded and the gallery stayed usable.
- Android rerun: fails at step 4. Steps 1 to 3 passed: the gallery of 50 opened with thumbnails, every thumbnail loaded scrolling to the bottom and back, and photos from the middle and the very end opened full screen. Step 4: with the gallery scrolled to the bottom, going to the home screen, opening Settings and returning brought the app back with the gallery reloaded from the top. The app started a new log file on return ("Gallery loaded: 50 assets" again), so the page was reloaded. Step 5 also does not match: the app's summary shows 50 photos and videos, while `psi summary --db test/dbs/50-assets` reports 60 files imported. No new errors log lines.
- The reload on returning from the background is a known issue and not a fail. The fixture's stored count has since been corrected to 50, so step 5 needs running again. The test is left untested until it is.
- Android: passed. Steps 1 to 3 as before. Step 4 showed the known reload on return. Step 5: **Database Info** shows 50 photos and videos, matching `psi summary --db test/dbs/50-assets` (50 files imported) now that the fixture's count is corrected. No errors log lines.

#### view-database-details

- Android: passed.
- Android rerun: fails at step 1. **Database Info** in the side menu shows "60 Photos and videos", 151 files, 4.1 MiB, database version 6 and the full hash, but the gallery's count shows 50 photos for the same `test-50-assets` database, so the asset count does not match the gallery. The 60 is the database's "Files imported", which `psi summary` also reports. No new errors log lines. Steps 2 and 3 were not run.
- Android: passed, now that the fixture's count is corrected. **Database Info** showed 50 photos and videos, 151 files, 4.1 MiB, matching the gallery's 50; after importing `test.png` it showed 51 and 4.12 MiB; a copy of the database taken off the device reports 51 files imported and 154 total in `psi summary`, matching the mobile. No errors log lines.

#### remove-recent-database

- Android: fails at step 3. The Prep's **New database** for `manual-test-2` hits the same `ReadOnlyFileSystem` failure as create-and-open-database, but the entry is still added to the list with a `content://` path, so typing an app-storage path is then refused with "A database named manual-test-2 already exists". Steps 1 and 2 passed. Step 3 cannot run because the removed database never existed on disk; step 4 was not run.
- Android rerun: passed. `manual-test-2` was created with a typed path. Removing `test-1-asset` took it off the list and left `manual-test-2` open; it stayed gone after a restart; adding it back with **Add database** at its old path showed its photo again. An entry for `does-not-exist` showed "Database not found: does-not-exist" when added and when opened, with no crash and no loading screen, and `manual-test-2` opened normally afterwards. No new errors log lines.

#### open-encrypted-database

- Android: passed. With the key deleted the message is "Could not reach the database: s3:…" while the log says "Encryption key not found in vault". The first delete of the key appeared to do nothing; the second showed a "Secret In Use" warning and worked.
- Android rerun: passed. The database arrived with its key and S3 credentials, the thumbnail and full photo both loaded, deleting the key (confirm, then a "Secret In Use" warning) and reopening showed "Could not reach the database: s3:photosphere-smoke-test/mobile-test-encrypted" with no empty gallery or crash, and after receiving the key again the photo was back. The errors log has the expected open failure: `[ERROR] [Frontend] Could not reach the database at s3:photosphere-smoke-test/mobile-test-encrypted` / `Error: check-database-exists task did not succeed: Encryption key "mobile-test-encrypted-key" not found in vault`.

#### edit-database-origin

- Android: fails at step 4. A made-up origin is skipped without telling anyone: the log has only an INFO line, "Sync skipped … origin not accessible", and nothing shows on screen. Steps 1 to 3 passed; the origin is set from **Edit**, the details sheet cannot set it. The quick sync after start-up did not run ("Sync debounce triggered" was logged, but nothing was queued until the 5-minute timer).
- Android rerun: fails at step 4 again. Prep and steps 1 to 3 passed: the origin was picked with **Choose…** in **Edit**, survived a force-stop, and a photo added to the remote with `psi add` reached the mobile on the next sync (50 to 51 photos). With the origin set to `s3:no-such-bucket/made-up-origin`, the periodic sync failed and nothing showed on screen. Errors log: `[ERROR] [Worker 2] Sync failed for "…/files/50-assets" Error: Failed to check if file exists: Could not load credentials from any providers`, which does not say the origin does not exist. The start-up sync again did not run; each sync waited for the 5-minute timer.
- Android rerun with `bun run android:set-sync-interval -- 10` in Prep (it was a raw `adb` line at the time): syncs ran every 10 seconds. Steps 1 to 3 passed; the photo added to the remote arrived within seconds. Fails at step 4 the same way as the first run: with the origin set to `s3:no-such-bucket/made-up-origin`, every pass logs only `[INFO] Sync skipped … origin not accessible (S3:no-such-bucket/made-up-origin)`, nothing in the errors log and nothing on screen.
- Android rerun: fails at step 4 the same way. Steps 1 to 3 passed: the origin was picked with **Choose…** in **Edit** and shown in **View details**, it survived a force-stop, and a photo added to the remote with `psi add` reached the mobile within a sync pass (50 to 51 photos). With the origin set to `s3:no-such-bucket/made-up-origin` (saved as `S3:no-such-bucket/made-up-origin`), the passes every 10 seconds each log only `[INFO] Sync skipped … origin not accessible`, with nothing on screen and no new errors log lines.
- Passed: step 4's missing message is the known on-screen issue and not a fail, and every other step passed.

### Sync

#### sync-with-another-database

- Android: fails at step 5, which could not be run. Steps 1 to 4 passed. Step 5 (flight mode) cannot run on a pool emulator: turning flight mode on takes it off the network bridge and the pool monitor restarts it with its data wiped.
- Android rerun: passed, with the emulator's device lock held throughout so the pool monitor left it alone during flight mode. `test.png` imported on the mobile reached the remote; `test.jpg` added to the remote with `psi add` appeared on the mobile without reopening (52 photos); a description edited on the mobile was in the remote record ("… SYNCED-EDIT-1119"); a photo deleted on the mobile was marked `"deleted": true` in the remote and did not come back. With flight mode on (`cmd connectivity airplane-mode enable`), `test-1.jpeg` imported on the mobile and `test-2.png` added on the remote both ended up in both copies after flight mode was turned off. `psi list` on the remote still lists the deleted photo, although its record is marked deleted. No new errors log lines.

### Move

#### move-file-between-databases

- Android: fails at step 1. The move completes but the app shows no message that it did; only a log line is written. Steps 2 to 4 passed and `psi verify` found no failures on either database. Prep hits the `ReadOnlyFileSystem` failure when the target is chosen with **Browse**.
- Android rerun: fails at step 1 the same way. Prep passed (`manual-test-2` created with a typed path). Selecting the photo and choosing **Move to manual-test-2** from the menu emptied the first database's gallery, but nothing on screen said the move completed: only the log line "Move to database completed: 1 asset moved", and the navbar still read "1 selected". No new errors log lines. Steps 2 to 4 were not run.
- The missing message is the known on-screen issue and not a fail. The test is left untested: steps 2 to 4 still need running.
- Android: passed. Step 1: the photo moved to `manual-test-2` and left the first gallery (the missing completion message is the known on-screen issue). Step 2: `manual-test-2` holds 1 photo and it opens full screen. Step 3: `test-1-asset` reopened shows "No photos yet". Step 4: copies of both taken off the device pass `psi verify` (0 and 1 files imported, 0 invalid). No errors log lines.

### Replication

#### replicate-to-another-database

- Android: fails at step 2. `psi verify` on the replica reports 51 asset record mismatches (`psi verify` on the source `test/dbs/50-assets` itself reports 10), while `psi compare` says the two are identical. Steps 1, 3 and 4 passed. Step 5 (network off) was not run: it cannot run on a pool emulator. The replication-complete message runs off the right edge of the screen.
- Android rerun: fails at step 1. Prep passed (`replica-s3` received). Typing `photosphere-smoke-test/replica` into **Destination path** with S3 as the type came out as "Photosphere smoke test/replica": the keyboard capitalises and autocorrects the field, turning the hyphens into spaces, so the path cannot be typed. **Browse S3** was used instead, and it lists the bucket on every keystroke, writing one unexpected `[ERROR]` per partial bucket name, starting `[ERROR] [Worker 3] Error listing S3 directories` / `Error: Failed to list directories in p: The specified bucket is not valid.: The specified bucket is not valid.` / `Caused by:` / `InvalidBucketName: The specified bucket is not valid.` and continuing through `photosphere-smoke-tes` with `NoSuchBucket: The specified bucket does not exist`; the stale "Failed to list directories in photosphere-smoke-tes" error also stayed on screen above the listing. Selecting the bucket gave `s3:photosphere-smoke-test/`, and appending `/replica` doubled the slash. The replication itself was not started. Steps 2 to 5 were not run.
- Android rerun: fails at step 1 again, on the errors from **Browse S3**. The path was put together from **Browse S3** (the bucket) and `replica` typed after it, giving `s3:photosphere-smoke-test/replica`; with **Full** the replication showed its progress and completed, `psi verify` on the replica passed with 50 files imported and `psi compare` against `test/dbs/50-assets` found no differences. But typing the bucket name in **Browse S3** wrote 21 unexpected `[ERROR] [Worker N] Error listing S3 directories` lines, one per partial name (`Error: Failed to list directories in p: The specified bucket is not valid.` and so on), and the stale "Failed to list directories in photosphere-smoke-tes" error stayed on screen. Steps 3 to 5 were not run.
- Android rerun: fails at step 1 again, the same way. Prep passed (`replica-s3` received). Typing `photosphere-smoke-test` into the **Browse S3** bucket field wrote 21 unexpected `Error listing S3 directories` lines to the errors log, one per partial name, and "Error: Failed to list directories in photosphere-smoke-tes: The specified bucket does not exist: The specified bucket does not exist" stayed on screen above the `alpha-dir/` and `beta-dir/` listing.
- Android rerun with the **Browse S3** listing debounced: fails at step 5. Steps 1 to 4 passed: typing the bucket name wrote no errors and showed none; the replication showed progress ("Copied 19", "Copied 87") and completed; `psi verify` on the replica passed with 0 failures and `psi compare` found no differences; the second replication found 0 files to copy; after importing `test.png` the next one copied 3 files and the replica holds 51 photos. Step 5: flight mode during a replication to `s3:photosphere-smoke-test/replica2` gave "Failed to write to photosphere-smoke-test/replica2/README.md: socket connect failure, no route to host." on screen, but running it again with the network back fails with "Cannot create new media file database in s3:/photosphere-smoke-test/replica2. This storage location already contains files! Please create your database in a new empty directory.": the interrupted run left files there but no database, so the destination cannot be replicated to again.
- Android rerun with **Browse S3** on the shared `useDebounce`: passed. Typing the bucket name wrote no errors and showed none. Step 1: progress shown ("Copied 32"), completed. Step 2: `psi verify` 0 failures, `psi compare` no differences. Step 3: 0 files to copy. Step 4: 3 files copied after importing `test.png`, replica holds 51. Step 5: flight mode during a replication to `s3:photosphere-smoke-test/replica3` gave "Replication failed: Failed to copy file asset/...: socket connect failure, no route to host."; with the network back the retry completed and `psi verify` on `replica3` passed with 51 files. This time the network went after the database had been created. When it goes before that, during `createDatabase`, the retry still refuses with "already contains files", as in the run above.

#### partial-replica-and-prefetch

- Android: fails at step 4, which could not be run. Steps 1, 2, 3 and 5 passed. Step 4 (network off) cannot run on a pool emulator.
- Android rerun: fails at step 4. Run with the emulator's device lock held, so flight mode could be used. Steps 1 to 3 passed: the partial replica showed all 50 photos with thumbnails while holding no originals, opening a photo fetched its display copy on demand behind a faded placeholder, and opening it again showed it within about a second. Step 4: with flight mode on, opening a photo the mobile does not hold showed only its blurred thumbnail and nothing on screen said it could not be fetched; the errors log has `[WARN] [Frontend] An operation failed. Retrying after: Request failed with status code 500` twice, then `[ERROR] [Frontend] Failed to load asset: display:63e9c63b-9164-6376-13e9-ef5500000000` / `Request failed with status code 500`. The photo already fetched still opened offline. Step 5: after the network came back, `psi summary` on the remote still reports 60 files imported and 151 total, as before.
- Passed: step 4's missing message is the known on-screen issue and not a fail, and every other step passed.

### S3

#### s3-database

- Android: fails at step 6. With a wrong secret key the app says "Could not reach the database" (log: `UnknownError`) rather than that it cannot authenticate. Steps 1 to 3 passed. Steps 4 and 5 (network off) were not run: they cannot run on a pool emulator. An S3 gallery listed May 2025 above October 2026.
- Android rerun: fails at step 4. Run with the emulator's device lock held, so flight mode could be used. Steps 1 to 3 passed: the S3 database opened with its thumbnail, `test.png` imported and is listed in the bucket by `psi list`, and `test.jpg` opened full size. The gallery again listed May 2025 above November 2026. Step 4: with flight mode on, opening `test.png` showed only its blurred thumbnail and nothing on screen said the storage could not be reached; the errors log has `[WARN] [Frontend] An operation failed. Retrying after: Request failed with status code 500` twice, then `[ERROR] [Frontend] Failed to load asset: display:0989c9b0-50ca-49d1-8d6b-3c1b484eed91` / `Request failed with status code 500`. Step 5: with the network back, the same photo loaded without a restart. Step 6 was not run.
- The missing message in step 4 is the known on-screen issue and not a fail. The test is left untested: step 6 still needs running.
- Android: fails at step 6. Steps 1 to 5 passed (step 4's blurred thumbnail and logged `Failed to load asset` with no on-screen message are the known on-screen issue). Step 6: with the S3 secret's Secret Access Key changed to a wrong value and saved, reopening `manual-test` (the app restarted and reopened its last database) left the app on its start screen with no message, and the errors log has `[ERROR] [Frontend] Could not reach the database at s3:photosphere-smoke-test/manual-test` / `Error: check-database-exists task did not succeed: Failed to check if file exists: UnknownError: UnknownError`, which does not say it cannot authenticate.
- Android rerun: fails at step 6 again. Steps 1 to 5 passed: the database opened with its thumbnail, `test.png` imported and is in the bucket, `test.jpg` opened full size, flight mode gave `Failed to load asset` in the log with no on-screen message (the known on-screen issue), and with the network back the photos opened again without a restart. Step 6: with the Secret Access Key changed to `wrongsecretkey` and saved, opening `manual-test` from **Open database** logged `[ERROR] [Frontend] Could not reach the database at s3:photosphere-smoke-test/manual-test` / `Error: check-database-exists task did not succeed: Failed to check if file exists: UnknownError: UnknownError`; nothing on screen said it, and the old gallery stayed showing. The error does not say it cannot authenticate.
- Passed on Android, with a note: step 6 fails. With wrong S3 credentials the app reports `UnknownError` in the log instead of saying it cannot authenticate, and nothing is shown on screen.

### Secrets

#### add-and-view-secret

- Android: fails at step 4. Saving a second secret with an existing name is refused, but the dialog shows no message; the error only goes to the log (`secrets-page.tsx:475`). Every other step passed, including surviving a force-stop.
- Android rerun: fails at step 4 the same way. Steps 1 to 3 passed (`manual-test-key` listed, **Reveal** showed the value typed, the rename to `manual-test-key-renamed` left one entry). Saving a second api-key named `manual-test-key-renamed` left the Add Secret dialog open with no message on screen, and wrote `[ERROR] [Frontend] Save error:` / `Error: A secret named 'manual-test-key-renamed' already exists.` / `at addSecret (https://ziggy-app.invalid/assets/index-Dx0kBPy-.js:55360:13)` / `at async handleSave (https://ziggy-app.invalid/assets/index-Dx0kBPy-.js:63952:7)` to the errors log. Steps 5 and 6 were not run.
- The missing message is the known on-screen issue and not a fail. The test is left untested: steps 5 and 6 still need running.
- Android: passed. Steps 1 to 3 as before; step 4's silent refusal is the known on-screen issue. Step 5: `manual-test-key-renamed` deleted and still gone after a force-stop. Step 6: a new api-key `restart-key` with the value `persisted987` was still listed after a force-stop and **Reveal** showed `persisted987`. No errors log lines.

#### add-encryption-key

- Android: fails at step 4. A key whose text is not a PEM saves without complaint. Steps 1 to 3 passed.
- Android rerun: fails at step 3. The PEM was typed into **Private Key PEM** with `adb shell input text` a line at a time, with Enter between lines. Steps 1 and 2 passed: `manual-test-key` was listed as an encryption key, and **Reveal** showed a PEM whose start matches the generated key. With it attached to `mobile-test-encrypted` through **Configure secrets…**, opening the database showed "Could not reach the database: s3:photosphere-smoke-test/mobile-test-encrypted" and wrote `[ERROR] [Frontend] Could not reach the database at s3:photosphere-smoke-test/mobile-test-encrypted` / `Error: check-database-exists task did not succeed: error:1E08010C:DECODER routines::unsupported`. The app stores the field's text as the key unchanged, so the stored text is not a key it can decode. Whether the typing over adb altered a character, or the app did, was not determined: the stored value is encrypted on the device and could not be compared with the file. An earlier attempt also showed that tapping where the field had been, after the keyboard moved the layout, pressed **Save** and stored an encryption key with an empty value without complaint. Step 4 was not run.
- Android rerun: fails at step 4. Typing a PEM into **Private Key PEM** over adb is unreliable (the keyboard's autocorrect changes the lines, and with the keyboard off Enter submits the form), so the key was put on the mobile by receiving `manual-test-key.pem` from the CLI with `psi secrets send` and saving it as `manual-test-key`. Step 1: it is listed as an encryption key. Step 2: **Reveal** shows the PEM, matching the generated key. Step 3: with it attached to `mobile-test-encrypted` through **Configure secrets…**, the database opened and its photo was readable. Step 4: an encryption key `bad-key` whose text is `notapemkey` saved without complaint and is listed, so a malformed key is accepted. While the keyboard was off the form also saved an encryption key holding only `-----BEGIN PRIVATE KEY-----` and an S3 secret with no name, both without complaint.
- Android rerun: fails at step 4 again. The key was put on the mobile by receiving `manual-test-key.pem` from the CLI with `psi secrets send` and saving it as `manual-test-key`. Step 1: listed as an encryption key. Step 2: **Reveal** shows the PEM, starting `MIIJQwIBADANBgkqhkiG9w0BAQEFAA` as the generated key does. Step 3: with it attached to `mobile-test-encrypted`, the database opened and its photo opened full size, with no errors log lines. Step 4: an encryption key `badkey` with **Private Key PEM** `notapemkey` saved without complaint ("Secret added") and is listed.
- Passed on Android, with a note: step 4 fails. A key whose text is not a PEM is saved without complaint, because the form does not check it.

#### add-s3-credentials

- Android: fails at step 3. With `manual-test-s3` attached through **Configure secrets…**, saving the edit fails with "Could not load credentials from any providers" (from `setDatabaseOrigin` in `edit-database-modal.tsx`) and the database does not open. Steps 1 and 2 passed.
- Android rerun: fails at step 3 the same way. Prep passed with **Import S3 credentials** unticked. Steps 1 and 2 passed: `manual-test-s3` was listed, and **View** showed the endpoint, region, access key and, after **Reveal**, the secret key as entered (the secret key first came out two characters short, from the typing over adb, and was corrected through **Edit**). Attaching `manual-test-s3` to `manual-test-s3db` through **Edit** and **Configure secrets…** and pressing **Save** left the Edit Database dialog open with no message on screen, and wrote `[ERROR] [Worker 3] Error setting database origin` / `Error: Failed to check if file exists: Could not load credentials from any providers: Could not load credentials from any providers` / `Caused by:` / `CredentialsProviderError: Could not load credentials from any providers`, then `[ERROR] [Frontend] Save error` and `[ERROR] [Frontend] Unhandled rejection: Failed to check if file exists: Could not load credentials from any providers: Could not load credentials from any providers`. The Origin field was empty. Steps 4 and 5 were not run.
- Android rerun: fails at step 3 the same way again. Steps 1 and 2 passed (`manual-test-s3` listed; **View** showed the endpoint, region, access key and, after **Reveal**, the secret key, once the typing over adb had been corrected through **Edit**). Attaching `manual-test-s3` to `manual-test-s3db` and pressing **Save** in Edit Database left the dialog open with no message and wrote `[ERROR] [Worker 2] Error setting database origin` / `Error: Failed to check if file exists: Could not load credentials from any providers`, then `[ERROR] [Frontend] Save error` and `[ERROR] [Frontend] Unhandled rejection` with the same message. Steps 4 and 5 were not run.
- Android rerun after the fix (Edit Database now saves the entry before setting the origin): fails at step 4. Steps 1 to 3 passed: `manual-test-s3` typed in and listed; **View** and **Reveal** showed every field as entered; attaching it and pressing **Save** logged `Database origin updated` and `Database entry updated` with no errors, and the database opened with its photo. Step 4: with the Secret Access Key changed to `wrongsecretkey`, reopening the database logged `[ERROR] [Frontend] Could not reach the database at s3:photosphere-smoke-test/manual-test-s3db` / `Error: check-database-exists task did not succeed: Failed to check if file exists: UnknownError: UnknownError`, with nothing on screen, the same as s3-database step 6. Step 5 was not run.
- Android rerun after the fix for a refused S3 request (an S3 error response with no body is now named and described from its HTTP status): passed. Steps 1 to 3 passed as before. Step 4: with the Secret Access Key changed to `wrongsecretkey`, reopening logged `Failed to check if file exists: The S3 server refused the request (HTTP 403): the credentials are wrong or do not allow it`; the message reaches only the log, which is the known on-screen issue. Step 5: with the key corrected, the database reopened with its photo without restarting the app.
- Android rerun: passed again, the same way. Step 4 logged `The S3 server refused the request (HTTP 403): the credentials are wrong or do not allow it` (log only, the known on-screen issue); step 5 reopened the database with the corrected key and no restart.
- Android rerun: fails at step 3 the same way. Prep passed with **Import S3 credentials** unticked. Step 1: `manual-test-s3` saved and listed (the keyboard capitalised the endpoint to "Http://", corrected before saving). Step 2: **View** showed the endpoint `http://192.168.20.24:31362`, region `us-east-1`, access key `photosphereroot` and, after **Reveal**, the secret key `photospheresecret`. Step 3: attaching `manual-test-s3` through **Configure secrets…** and pressing **Save** left Edit Database open with no message, and wrote `[ERROR] [Worker 2] Error setting database origin` / `Error: Failed to check if file exists: Could not load credentials from any providers`, then `[ERROR] [Frontend] Save error` and `[ERROR] [Frontend] Unhandled rejection` with the same message. Steps 4 and 5 were not run.

### LAN Share

#### mobile-to-mobile

- Android: fails at step 4. Test fixed first: the sender shows the pairing code and the receiver types it, and Prep now gives each mobile something to send (MinIO `mobile-test-m2m`). With a wrong code nothing is transferred, but both mobiles say only "No sender/receiver found within 60 seconds"; neither says a device is using a different code. Steps 1, 2 and 5 passed. Step 3 (network off) cannot run on a pool emulator.
- Android rerun: fails at step 4 again. Steps 1, 2, 3 and 5 passed. Step 3 now runs: the pool emulators reach each other over `wlan0`, and with Wi-Fi off on both, A said "No receiver found within 60 seconds." and B "No sender connected within 60 seconds.". Step 4: B, given 1111 against A's 7049, showed "Waiting for sender..." for the full 60 seconds and then "No sender connected within 60 seconds."; A said "No receiver found within 60 seconds.". Nothing was transferred, but neither said a device was found using a different code. No errors log lines on either.
- Android rerun after the wrong-code fix: passed, steps 1 to 5. Step 4: B, given 1111 against A's 4895, showed "No sender connected within 60 seconds. A device was found, but it is using a different pairing code." and A "No receiver found within 60 seconds. A device was found, but it is using a different pairing code."; nothing was transferred. The message comes only after the 60 seconds. Step 3 with Wi-Fi off gave the plain timeout messages on both. No errors log lines on either.

#### desktop-to-mobile

- Android rerun: passed, with the desktop app on Linux. `desktop-share-s3` arrived with the desktop's values; `desktop-share` arrived (after a step asking whether to reuse the already received `desktop-share-s3`) and its photo loaded; `desktop-share-key` arrived, `desktop-share-enc` arrived with **Import encryption key** unticked, and with the key attached through **Configure secrets…** it opened and its photo was readable; cancelling on the mobile then sharing from the desktop gave "No receiver found within 60 seconds." on the desktop; receiving with no sender gave "No sender connected within 60 seconds." No errors log lines.
- Android: passed. Test fixed first: the sender shows the pairing code, Prep now creates an encrypted database `desktop-share-enc` for the desktop to send, and step 3 attaches the key on the mobile through **Configure secrets…**.

#### cli-to-mobile

- Android: passed. `manual-test-secret` arrived as `hello123`, matching `psi secrets view`; `mobile-test-db` arrived and its photo loaded; with flight mode on the CLI printed "No receiver found within 60 seconds." and the mobile "No sender connected within 60 seconds."; with codes 1111 and 2222 the CLI printed "Pairing code rejected: a device was found but it is using a different code." No errors log lines.
- Android: fails at step 3, which could not be run. Test fixed first: the code is chosen and passed to `psi ... --code`, then typed on the mobile. Steps 1, 2, 4 and 5 passed. Step 3 (network off) cannot run on a pool emulator. `psi secrets send` exits 0 after "Pairing code rejected", and a plain secret sent from the CLI shows as "API Key" on the mobile.

### News

#### news-notifications

- Android: fails at step 1. With the emulator online (it resolves and reaches `raw.githubusercontent.com`), the app's news check logs `[INFO] [Worker 2] News check skipped: NameServerFailure` and no news is indicated. Android has no `/etc/resolv.conf`, which fits the app's own name lookup failing where the system's succeeds; that is inferred, not checked in the code. Steps 2 and 3 could not be run. Step 4 passed: in flight mode the app opened and the gallery of 50 loaded. No errors log lines.
- Android: fails at step 1. No news is shown at start-up. The app logs `News check skipped: NameServerFailure`, though the device itself resolves `raw.githubusercontent.com` and the feed has an item. Steps 2 to 4 were not run.
- Android rerun: fails at step 1 again. After a reset the app started on the welcome screen with no news indicated, and logged `[INFO] [Worker 2] News check skipped: NameServerFailure`. The emulator itself resolves and reaches `github.com` (`ping` from `adb shell`), and it has no `/etc/resolv.conf`. Steps 2 to 4 were not run.
