# E2E Test Checklist Notes

Notes from manual test runs of [CHECKLIST.md](CHECKLIST.md). Headings and test names match the checklist.

Upcoming version: 0.0.9

## CLI

### Import

#### add-and-verify

- The size of an added file is not recorded in its asset record. Adding `test/test.jpg` (2,049,800 bytes) printed `Total size: 0 Bytes` and `Average size: 0 Bytes`, and `list` shows `Size: Unknown` for it. `verify` counts 2.58 MiB on disk, so the files are stored; only the recorded size is missing.
- The `0 Bytes` in the `add` summary is explained by `addPaths` in `packages/node-api/src/lib/import.ts`: `totalSize` starts at 0 and nothing adds to it. Why `list` shows `Size: Unknown` has not been checked.

#### add-duplicate-content

- Test step 1 expects the output to show both files processed, but it reports `Files considered: 1` for a directory holding two identical files. Dedupe itself works: `summary` shows `Files imported: 1` and verify passes. The duplicate is dropped from the counts because `import-assets.worker.ts` skips a file that duplicates one already queued in the same run without sending a message, so `addPaths` never counts it as added, already added or ignored. Its log line also prints `File ""` with no file name. Not decided yet whether the code is wrong and the test is right, or the code is fine and the test's expectation is wrong.

#### add-multiple-files

- Failed at Test step 1: expected `Files added: 3`, got `Files added: 5`; `check` then reported `Already added: 5` and `verify` reported `Files imported: 5`, against an expected 3. The test is wrong about the fixture: it says `test-archive.zip` holds the same files as the directory, so they dedupe, but the zip holds `PXL_20260322_023611216.mp4` and `test-3.jpg`, which differ from `test-1.jpeg`, `test-2.png` and `test.mp4`. The two files from the zip were imported under UUID names (`b459eba0-....jpg`, `484b07be-....mp4`) with a temporary path (`/tmp/photosphere/<uuid>/file-scanner`), not their names inside the zip.

#### add-zip

- **revist and confirm** This needs testing and needs a smoke test.
- Failed at Test step 1 and Check step 2: expected `Files added: 3` and `test-1.jpeg`, `test-2.png` and `test.mp4` listed, got `Files added: 2`. The zip holds two files, `PXL_20260322_023611216.mp4` and `test-3.jpg`, so the test's expectation does not match the fixture. Both were listed under UUID file names (`a63c6d98-....jpg`, `f3f70f6d-....mp4`) with path `/tmp/photosphere/<uuid>/file-scanner`, not their names inside the zip, and both dated today (10/26/2026) although the zip entries are dated 2026-06-01. Verify passed with `Files imported: 2`.

### Inspect

#### list-paging

- Failed at Test step 1: the 50-assets fixture holds 60 assets (`summary` shows `Files imported: 60`), but `list --page-size 20 --yes` showed only `--- Page 1 ---` with 20 files and then `End of results. Displayed 20 files total.` No second page and no "Press Enter" prompt. With `--page-size 100` it showed one page of 50 files and `Displayed 50 files total.`, so 10 assets never appear whatever the page size. In `apps/cli/src/cmd/list.ts`, `list` keeps only the first `pageSize` records of each page the database returns and moves on only when the database gives a `nextPageId`.

### Verify

#### verify-full

- Failed at Test step 2: the output of `verify --full` is line for line the same as the quick `verify`, so nothing indicates that file hashes were checked, which the test expects. Every count passed (`New:`, `Modified:` and `Removed:` all 0).

### Sync

#### sync-copy-to-original

- The test file's `cp -r ../../test/dbs/v6 /tmp/psi-test/original` failed with `cannot create directory '/tmp/psi-test/original': No such file or directory`, because the step before removes `/tmp/psi-test`. Added `mkdir -p /tmp/psi-test` to the prep of every test that copies the v6 fixture (all six sync tests and replicate-deleted-asset). With that, the test passed.
- `sync` prints a raw JSON line, `Sync timings: {"filesCopied":3,...}`, in its normal output.

#### sync-edit-field-copy

- The test file used a `<bdb-cli>` placeholder. Replaced with `bun run ../bdb-cli/src/index.ts`, which is how the smoke tests run it from source.

### Move

#### move-file-between-databases

- **revist and confirm** This command doesn't exist yet.
- Failed at Test step 1: `error: unknown command 'move'` (`Did you mean remove?`). The file stayed in the source database.

### Replication

#### replicate-deleted-asset

- Passed, but proves little: the v6 fixture holds only one asset, so removing it leaves an empty database and the replica copied 0 files and 0 records.

#### replicate-partial-copy

- Failed at Check step 2: the replica's `list` shows `No files found in the database.`, while `verify` on the replica reports `Files imported: 1` and passes, and `origin` shows `/tmp/psi-test/source`. The replicate step reported `Total files copied: 0` and `Total records copied: 0`. The test file already marked this step "not currently working".

#### replicate-unrelated-fails

- Passed, but the refusal is printed as `An unknown error occurred` followed by a stack trace and a `psi bug` prompt, although it is an expected, explained refusal.

### Upgrade

#### add-file-after-upgrade

- Passed, but the test never upgrades anything: it copies the v6 fixture, which is already the current version. Its title says "Freshly-Upgraded".

### Databases (dbs)

#### add-and-list

- The CLI now reads `databases.toml`, but seven `dbs` tests (add-and-list, view, edit-rename, remove, clear, resolve-by-name, resolve-by-path) seeded `databases.json`, so as written they failed (`No database matching the given name or path was found.`) or passed without testing anything (clear). Rewrote their seeds as `databases.toml`, after which all of them passed. The no-match-fallback test was changed the same way.

### LAN Share

#### share-database

- As written this test could not pass: it seeded `databases.json`, and `dbs send` without `--yes` stops at an interactive "Database name" field prompt. With stdin not a terminal, `dbs send` then exited with status 0 having sent nothing. With a `databases.toml` seed and `--yes` the share passed.
- The test said `dbs send` and `secrets send` wait "60 seconds unless `--timeout <seconds>` says otherwise", but neither command has a `--timeout` option (`error: unknown option '--timeout'`). Removed from the test.

### Misc

#### config-timestamps

- Failed: `.db/config.json` never contains `lastModifiedAt` or `lastSyncedAt` (it holds `{}` or just `origin`). Those values now live in the binary `.db/state.dat`, and no CLI command prints them, so the test cannot be run as written. Marked it out of date in the test file.
- In its sync step, `sync` printed `Databases already in sync, nothing to do.` straight after `replicate`, so no sync timestamp would be written there anyway.

#### mcp-server

- The test said `psi mcp` was not implemented and used `mcp --db`, which fails with `error: unknown option '--db'`. The command exists and serves tools (`list_databases`, `open_database`, `list_media_files` and others), not resources. Rewrote the test to drive it over stdio, and it passed: `open_database` opened the test database and `list_media_files` returned `test.jpg`.
- `psi mcp` does not exit when its stdin closes, so the test run hung until it was stopped. The rewritten test wraps it in `timeout 30`. An MCP client that closes stdin to end a session leaves the server running.

#### info

- Failed at Test step 1: `info ../../test/test.jpg` shows type, hash, size, the file's modified time and dimensions, but no EXIF date. The photo's date (`2025-05-27T09:54:16`) appears only in step 2, as `Photo date` in the database record.
- Failed at Test step 3: `info` on a file that does not exist printed `Info for 0 item(s):` and `Displayed info for 0 item(s).` and exited 0, with no error.
- In step 2 the asset's `Labels` are the folders of the path it was added from: `home, ash, projects, photosphere, photosphere, test`.

#### bug

- Failed at Test step 1: `bug --no-browser --yes` printed `✓ Bug report opened in browser!` and no issue link, so `--no-browser` was ignored and the browser was asked to open the GitHub new-issue page. Commander turns `--no-browser` into `options.browser = false`, but `apps/cli/src/cmd/bug.ts` checks `options.noBrowser`, which is never set.

### Origin

#### consolidate-unrelated-remote

- Passed. Sync's refusal of the two unrelated databases in Test step 1 is printed as `An unknown error occurred` with two stack traces and a `psi bug` prompt.
- `consolidate` printed `Failed to acquire write lock after 3 attempts. Lock is currently held by "<id>" since 3s ago` part way through, then completed and reported success.

### S3

#### s3-database

- Passed. After creating a database on S3, `init` suggests `cd s3:photosphere-smoke-test/manual-test`, which is not a directory.

### Vault (keychain)

#### add-view-edit-delete

- Not run. Both keychain tests add and remove secrets with fixed names in the real OS keychain of the machine running them, so they were left for the human to run.

### General

- Every command that fails prints `Temporary files retained for inspection: /tmp/photosphere/<uuid>`, so each failed command leaves a directory behind under `/tmp/photosphere`.
- Every command against a fresh config directory prints the `📰 News:` block first, including `dbs add`.

## Desktop

All desktop results below come from a test-hooks build of the app driven through its control connection on Linux, one isolated instance per test.

### General

- The "Import complete" toast never closes on its own (`duration: 0` in `main.tsx`), and it sits on top of later toasts, even after switching databases.
- The navbar badge says "1 photos", and the import toast for a video says "View photo".
- The Actions column on Manage Databases runs off the right edge of a 1200px window: the last icon is cut off and the Edit button is out of view.
- The About page gives the MCP URL as the fixed `localhost:3475`, but in test mode the server picks a free port (51375 in this run).
- Exporting `XDG_DATA_HOME` as the desktop tests' Prep says also moves mise's data folder, so in the CLI terminal `mise exec -- bun` failed with "bun couldn't exec". Anyone whose bun comes from mise hits this.

### Import

#### import-directory

- **revist and confirm** Problem importing from the zip file
    - Import files have uuid for file name and a wierd path.
    - No immediate need to fix this.

#### import-video

- Passed. Import, the video thumbnail with its play icon, `video/mp4` in the CLI list and verify all passed, and the human confirmed the video plays.

#### import-zip

- **revist and confirm** This will work but will have a similar problem as above.
- Failed at Test step 2: expected `test-1.jpeg`, `test-2.png` and `test.mp4`, got "2 assets imported". The zip holds `PXL_20260322_023611216.mp4` and `test-3.jpg`, so the test's expectation does not match the fixture. The CLI lists them as `1a1283e9-….jpg` and `328eb970-….mp4`, so the names inside the zip are lost. The CLI checks passed.

### Move

#### move-file-between-databases

- Failed at Test step 2: the test says to click "Import photos", but the Import page's button is "Import files". Every other step passed: the asset moved to the destination database.
- After moving the selected asset, the navbar still says "1 selected".

### Download

#### download-single-asset

- Failed at Test step 2: the test names an "Import photos" button that the Import page does not have ("Import files"). The download passed: `Downloaded "test.jpg"` with Open Folder, and the file is byte-identical to the original.

#### download-multiple-assets

- Failed at Test step 2: same "Import photos" button that does not exist. The download passed: "Downloaded 2 assets", both files byte-identical.

### Replication

#### replicate-full-copy

- Failed at Test step 2: same "Import photos" button that does not exist. The full replica passed, with the right origin.

#### replicate-partial-copy

- Failed at Test step 2: same "Import photos" button that does not exist.
- Failed at step 6: expected `test.jpg` in the replica, `list` printed "No files found in the database." Verify and origin passed.

### Database

#### view-database-details

- Failed at Test step 2: the test expects an asset count, but the View Database dialog shows only Name, Description, Path, Origin and Linked Secrets.

### Secrets

#### add-duplicate-name

- **revist and confirm** This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
- **revist and confirm** It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.
- Failed at Test step 2: no error appears in the UI and the dialog stays open. The error reaches only app.log: "Error: A secret named 'dup-secret' already exists." Step 3 passed: the vault still holds only the original value.

#### add-api-key

- **revist and confirm** Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
- **revist and confirm** The should be a button that reveals the secret in the input while we are entering it.
- Failed at Test steps 2 and 4: after the eye button, the value shows as `••••••••••` until Reveal is clicked, which the test does not mention. After Reveal the value and the CLI output were correct.

#### add-encryption-key

- Failed at Test steps 2 and 4: the value shows as `••••••••••` until Reveal is clicked, which the test does not mention. After Reveal the PEM and the CLI output were correct.

#### add-s3-credentials

- Failed at Test steps 2 and 4: the values show as `••••••••••` until Reveal is clicked, which the test does not mention. After Reveal every field and the CLI output were correct, with no `label` field.

#### rename-secret

- Failed at Test step 3: `secrets list` prints a table row `new-name  api-key  ****`, not the `Type: api-key` text the test names. `old-name` is gone, as expected.

#### view-secret

- Passed. "Add secret" with only a name filled in saves an `s3-credentials` secret with every field empty, and nothing checks for it.

### LAN Share

#### share-database

- **revist and confirm** When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.
- Failed at Test step 5: the value shows as `••••••••••` until Reveal is clicked, which the test does not mention. After Reveal the key matched.
- app.log has `[ERROR] Could not reach the database at …/sender/test-db` with `error:1E08010C:DECODER routines::unsupported`, caused by the test's made-up path and placeholder PEM.

### MCP

#### mcp-server

- Failed at Test steps 2 and 4: the test says to turn MCP on and off, but the app has no control for it. The server starts with the app and stops only when the app quits.
- Failed at Test step 3: `resources/list` returns "Method not found", because the server offers tools only. `get_media_file_info` returned correct metadata for a fixture asset.

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
