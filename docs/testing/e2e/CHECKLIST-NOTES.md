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
