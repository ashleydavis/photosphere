# E2E Test Checklist Notes

Notes from manual test runs of [CHECKLIST.md](CHECKLIST.md). Headings and test names match the checklist.

Upcoming version: 0.0.9

## CLI

### Import

#### add-and-verify

#### add-zip

- **revist and confirm** This needs testing and needs a smoke test.

### Move

#### move-file-between-databases

- **revist and confirm** This command doesn't exist yet.

## Desktop

### Import

#### import-directory

- **revist and confirm** Problem importing from the zip file
    - Import files have uuid for file name and a wierd path.
    - No immediate need to fix this.

#### import-video

- **revist and confirm** Video imports, but doesn't play back.

#### import-zip

- **revist and confirm** This will work but will have a similar problem as above.

### Secrets

#### add-duplicate-name

- **revist and confirm** This fails. Clicking Save has no effect for the duplicate secret, no error/toast is shown.
- **revist and confirm** It would be good when typing in the duplicate secret name in the Add Secret modal if it shows you in the form that the name is duplicate.

#### add-api-key

- **revist and confirm** Should not be able to save unless a value is entered. Blank values are useless and should not be allowed.
- **revist and confirm** The should be a button that reveals the secret in the input while we are entering it.

### LAN Share

#### share-database

- **revist and confirm** When it tried to create db (with a fake path), the Create Database modal didn't dismiss automatically even though the new db appeared in the Manage Databases list.

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
