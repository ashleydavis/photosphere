# Automatic photo backup

Photosphere can take photos in from where they arrive, on its own, and push them to a remote copy. This describes the engine that does it, the command that drives it today, and what each platform can and cannot do.

## What it does

Point Photosphere at one or more places where photos turn up and it will:

- import anything that is already there, as fast as the machine manages;
- import anything new on its next pass, a short while after the last one ended;
- push what it imported to a remote database, when one is configured, including while the app is not on screen (see [Syncing](syncing.md), which is the other half of this feature and describes it in full);
- optionally delete the source file once the photo is confirmed in the local database;
- optionally drop local originals the remote already holds, so the local database can stay small.

Nothing about the file handling is new. Automatic import is the same `import-assets` task a manual import runs, fed by a scanner that reads the configured sources instead of a fixed list of paths, so deduplication by content hash, the write lock, derivative generation and the hash cache all behave exactly as they do for a manual `psi add`. There used to be a second task that decided what to import and started an `import-assets` for every handful it released, which paid for the scan, the write lock and the hash cache per handful.

## How it avoids re-importing what it has already imported

A photo library item is not a file. On a phone it has no path at all until it has been copied out of the library into the app's sandbox, and that copy is deleted again as soon as the import finishes. Copying every photo in the library on every run, only to find each one already in the database, is the most expensive thing automatic import can do, and on a device with a few thousand photos it is most of what it does.

So each item is looked up before it is opened, in the hash cache:

- **An asset id recorded against it** means the photo is in this database. It is skipped: no copy, no hash, no database read.
- **A hash but no asset id** means an earlier run hashed it but did not get as far as recording where it landed. The database's hash index is asked, exactly as the import itself does, and the answer is recorded so it is not asked twice.
- **Nothing at all** means the item is copied, hashed and imported the long way, and what that costs is recorded so the next run does not pay it again.

Three things have to agree before a cache entry is believed: the item's identity, its size, and its created time. A photo library is free to hand a deleted item's identity to a new one, and a stale hit there would skip a photo that had never been imported.

The identity is `IMediaItem.sourceId`, which is a different thing on each platform and does not change between listings: the file's path for a watched folder, the MediaStore id on Android, the `PHAsset` local identifier on iOS.

There is one hash cache per database, because an entry now records the id its file has in that database, and the same photo imported into two databases has two ids. Clearing a cache loses nothing: everything in it can be recomputed, and the next run simply pays the full cost once. `psi hash-cache clear --db <path>` does that.

Once a run has read the whole listing, entries for items the library no longer holds are dropped, so the cache does not grow forever on a device where photos come and go. Only entries filed under a photo library identity are considered: a file path that is not in the photo library is a manual import, not a dead entry.

### Where the cache lives

This machine keeps a cache directory per database, and the hash cache is one thing inside it. The [import record](#where-the-record-lives) is the other:

```
<platform cache location>/           getCacheDir()
    <a hash of the database path>/   getDatabaseCacheDir(databasePath)
        imports.dat                  getImportRecordPath(databasePath)
        hash-cache/                  getHashCacheDir(databasePath)
            hash-cache-x.dat
```

The platform cache location is `$XDG_CACHE_HOME` or `~/.cache` on Linux and the other Unixes, `~/Library/Caches` on macOS, `%LOCALAPPDATA%` on Windows, and the app's storage sandbox on iOS and Android, each with `photosphere` under it. `PHOTOSPHERE_CACHE_DIR` overrides all of that, and the test temp allocator sets it for every suite so a run cannot reach the real caches. `psi hash-cache dir --db <path>` prints the whole directory for one database, and `psi version` prints the root they all sit under.

The database path is hashed rather than used directly, because it can be a Windows path or a URL-ish `s3:bucket:/path`, neither of which is safe to paste into a directory name.

Note that this is deliberately not kept beside the settings in `~/.config/photosphere`. Nothing in the cache is a setting, none of it is worth backing up, and the platform's cache location is where an operating system, a backup tool and a disk cleaner all expect to find something like it.

It is also not inside the database, and not under a temp directory:

- **Not inside the database.** A database can be an S3 bucket with no local directory at all, and one on shared storage is opened by several machines at once. A cache kept there would be read and written by all of them with no lock and no merge, so the last writer would erase what the others had learnt, and what each machine knows is useless to the others anyway: the entries are keyed by that machine's own file paths and that device's own photo library ids.
- **Not under a temp directory.** "Disposable" and "deleted without warning" are not the same thing. A temp directory is swept by something the app never hears about (Linux clears `/tmp` at boot, macOS reaps `/var/folders` after a few untouched days), and everything the cache avoids is then paid again with nothing to say why.

The identity a cache entry is filed under is normalised before it is stored or looked up: a leading slash goes and a backslash becomes a forward slash. Every path that reaches the cache goes through the same normalisation, in both directions, so that a watched folder's absolute paths on Linux and macOS and its `C:\...` paths on Windows are recognised again on the next run.

## The command

```bash
psi add --db ./photos --watch                       # keep importing from this operating system's photo folders
psi add --db ./photos --watch ~/Pictures ~/Camera   # keep importing from specific folders
psi add --db ./photos --watch --cleanup             # delete the source files the database holds, after
psi sync --db ./photos --watch                      # push to the origin as the database changes
```

Importing and syncing are two commands rather than one. `psi add --watch` knows nothing about the origin; `psi sync --watch` pushes what is there. Run them side by side to get both, and each half stays separately useful and separately testable.

`psi add` without `--watch` is unchanged: it walks what it is given once and stops.

With no folders given it uses the operating system's own photo locations: `Pictures` and `Pictures\Camera Roll` on Windows, `Pictures` on macOS, and the XDG pictures directory (falling back to `~/Pictures`) on Linux. Only folders that actually exist are read.

`psi add` without `--watch` imports what is there now and exits, and exits non-zero if any file failed. That is what makes it usable from a scheduler: a backup that did not happen must not look like one that did. It is also the same import task and the same file handling a watch uses, so nearly all of the automatic import path is covered by testing this one command.

With `--watch` it runs the same import over and over, five seconds apart, until interrupted. Ctrl-C stops it.

## Passes, not watching

A run reads its sources from the first page of the listing to the last, imports what is new, and ends. The app starts another a short while later: about thirty seconds on the desktop and on mobile, five on the CLI's `psi add --watch`. Nothing is left watching a filesystem or a photo library in between.

That is a deliberate reversal of what this used to do. The old engine held filesystem watchers, polled every source every thirty seconds, and re-walked the whole listing whenever any of them reported a change, all inside a task that never ended. The watchers were worth little: recursive directory watching is not available on Linux at all and is not dependable across network and removable filesystems anywhere, so the poll was doing the real work everywhere, and on a phone there was no change notification to hook at all. What is left is the part that was doing the work.

The cost of a pass is a listing plus one hash cache lookup per item, because a photo already imported is recognised before it is opened. That is what makes running it over and over cheap, and it is why nothing needs to remember where the last pass got to: every run starts at the beginning.

The consequence to know about is latency. A photo that arrives is imported by the next pass rather than the moment it lands, so the wait is up to one interval plus however long the pass takes.

## Nothing is paced

Items are imported as fast as the machine manages. There used to be a rate limit, 60 items a minute by default, on the reasoning that backfilling years of photos would otherwise make the machine unusable. It was removed: nothing had ever measured the machine being made unusable, and the limit was the only thing setting the length of a full import. Measured on a Pixel 6 against a real library of 2,291 items, a full import took 45 minutes with it and 40 without.

A run that is cancelled part way, by the app quitting or the setting being switched off, simply stops. Nothing is written down about where it had reached: the next run starts at the beginning of the listing again and the hash cache is what stops it re-importing anything.

## Deleting the source file

Deleting the source is its own operation rather than something the import does as it goes. On a phone every deletion raises a system confirmation, so doing it during the import asked the user once per handful of photos; done separately it asks once, at a moment they chose.

It answers its own question. For each item the device still holds it asks the hash cache what that photo hashes to, and the database whether it holds that hash. Nothing is deleted because an import reported success: the database saying it holds the content is the only thing that counts. A photo imported on another device and synced in is left alone, because this device never hashed it and finding out would mean copying and hashing the whole library.

On mobile it is a button in the automatic import settings. It counts first and says what it found; a second press deletes. On the CLI there is no confirmation dialog to spare the user, so `psi add --watch --cleanup` runs the same walk once, after the import has finished.

Either way it is off unless asked for, and deliberately so: it has nothing to do with the remote. A user who deletes their source files with no remote connected is trusting a single local copy.

## Dropping local originals

Once a local database is connected to a remote it is a partial replica of it, which means it does not have to keep every original on the device: an original the remote holds can be fetched back when it is wanted.

Dropping them is a setting the app turns on, not something the CLI offers: a one-shot command must never silently delete someone's local files, and it is not a use case on the desktop machines where the CLI is used. Only the original and the transcoded display copy go; the thumbnail and the micro thumbnail stay, which is what keeps the gallery browsable with no network at all. An original the origin does not hold with a matching hash is never dropped, whatever else is going on.

Which originals go is decided by a retention policy. They are implemented, exported and unit tested in `packages/api/src/lib/retention-policy.ts`:

| Policy | What it keeps |
|---|---|
| `SizeBudgetRetentionPolicy` | Local originals under a byte cap, dropping the oldest confirmed first. |
| `RecentDaysRetentionPolicy` | Originals imported within the last N days. |
| `FreeSpaceRetentionPolicy` | Enough free space on the device, dropping the oldest confirmed until there is. |
| `DropWhenConfirmedRetentionPolicy` | No confirmed originals at all: the smallest possible local database. |

The active one is `ACTIVE_RETENTION_POLICY` at the bottom of that file. The others are written out beneath it and commented out, so switching policy is uncommenting one line.

`localOriginalBudgetBytes` on the eviction task overrides the cap for one run without changing the code, which is what lets the unit tests exercise eviction with ordinary-sized photos rather than needing more than two gigabytes of test data.

## Connecting to a remote

Sync refuses to run between two databases that are not related to each other, and this feature does not weaken that refusal. `psi consolidate` is the separate, explicit operation that makes them related:

```bash
psi consolidate --db ./photos ./backup                  # a directory
psi consolidate --db ./photos s3:my-bucket:/photos      # an S3 location
```

It looks at what is there and picks between three cases:

- **Nothing at the remote path.** The remote is created as a copy of this database, which carries the database id across, and the origin is recorded.
- **A database that is not related.** The two are consolidated. Local content the remote does not have, compared by content hash rather than by asset id, is pushed to it. Content the remote already holds is not pushed a second time, whatever id it has there. The local database then becomes a partial replica of the remote: it adopts the remote's database id, records it as its origin, takes on the remote's records and thumbnails, and is marked partial.
- **A database that is already related.** The origin is recorded and nothing moves.

After any of the three, ordinary `psi sync` works.

Two machines each connected to the same remote end up with each other's photos: each pushes what the remote does not have, and each pulls the rest.

## What was imported

Every import, whether the user asked for it or it arrived on its own, is written to this machine's import record for that database. The Import page shows it, newest first, so opening a database answers "what came in?" rather than only showing what has happened since the app started. Each row is badged **manual** or **automatic**, because a photo that arrived on its own is the one a user is most likely to be asking about.

The record holds the last 1000 imports. When it is full the oldest go and the page says so, rather than presenting a partial history as a complete one.

### Where the record lives

It is a local file, `imports.dat`, in the same per-database cache directory the hash cache sits in. [Where the cache lives](#where-the-cache-lives) has the layout, the platform locations, and why the database path is hashed rather than used directly.

`getImportRecordPath` is the only thing that works the path out. Nothing else derives it, in TypeScript or in a smoke test's shell: a second copy of the derivation would go stale silently the moment this one changed, and the test standing on it would then be checking a file nothing writes. The smoke tests search the cache directory for `imports.dat` instead, which is exact because every suite runs with `PHOTOSPHERE_CACHE_DIR` pointed at a directory of its own.

**It is never read or written through `IStorage`, on any platform.** It is reached through the local filesystem and nothing else. That is not a detail of the implementation, it is the whole point: `IStorage` is how the database is reached, and this is not part of the database.

**It never travels**, and no arrangement is needed to keep it from travelling. It is not in the database, so sync, replication and consolidation cannot carry it: they copy what the merkle tree indexes, and the tree indexes the database. It is this machine's account of what it did, not part of the photo collection, and a record that travelled would show one machine's imports as another's. `87-import-record` proves no `imports.dat` appears anywhere inside the database directory after any of the three.

Keeping it here is what makes it true. It used to sit inside the database at `.db/imports.dat`, where a database on shared storage and every S3 database is opened by more than one machine, and each did a full read-modify-write of that one file with no lock and no merge, so the last writer erased what the others had recorded. The file went on presenting itself as a complete account of what this machine imported while holding whatever the most recent machine happened to write. On the machine it belongs to, two writers into the same database (the CLI and the desktop app at once, say) merge instead: the update runs under a lock beside the file and is re-run if the file moved underneath it.

Being a local file also means a flush costs a local read and write rather than, on an S3 database, a GET and a PUT of the whole record, and on an encrypted database a decrypt and encrypt of the whole record. It is written once every `IMPORT_RECORD_FLUSH_SIZE` photos.

It is plaintext, including for an encrypted database, exactly as the hash cache beside it already is. The hash cache holds this machine's source file paths, content hashes and asset ids for that database in plaintext; the record holds paths, outcomes and a micro thumbnail per entry. The photos it names were on this machine in the clear when they were imported, so the record exposes nothing that machine did not already hold. What encryption protects is the database, which is what leaves the machine.

There is no migration from the old location, because no database has a record written there. Nothing reads it and nothing deletes it: a machine's record starts empty and fills from its next import.

Losing it costs nothing but the history: an unreadable record reads as empty, and a record that cannot be written does not fail the import, because by then the photos are already in the database. Clearing the machine's caches loses it, which is a real cost the hash cache does not have: the hash cache can be recomputed from the files and this cannot. It is kept here anyway, because a per-database directory the operating system already knows how to reap is worth more than a history of imports nobody has asked to keep forever.

## What each platform can do

| | CLI | Desktop | Mobile |
|---|---|---|---|
| Import from folders | Yes | Yes | Not applicable |
| Import from the device photo library | No | No | Yes |
| Cleanup | Yes | Yes | Yes |
| Eviction | Yes | Yes | No (the task exists but nothing on mobile queues it) |
| Consolidation | Yes | Yes | No |

The engine is platform-neutral and lives in `packages/api`, with the Node-side parts in `packages/node-api`. The only platform-specific part is the media source: `FolderMediaSource` covers folders on a filesystem and `DeviceMediaSource` covers the device photo library. The scanner itself talks only to `IMediaSource` and knows about neither.

On the desktop the settings live on the configuration dialog and the settings page: a toggle, the folders being read, and whether the source file is deleted after import. Switching the toggle on creates a private photo database under the application data directory, lists it as "My Photos" and marks it as the one automatic import writes to. The main process starts and stops the task as the settings change, so nothing needs restarting.

On mobile the same thing happens and the user does the same thing: switch the toggle on, and the app makes its private database, asks for the photo permission, walks the device photo library and imports what it finds, including photos taken while it is running. It runs the same `import-assets` task the CLI and the desktop run, reading the photo library through the same host bridge the rest of the worker code uses. The only difference is which media source is registered underneath.

The `import-assets` task holds an engine slot for as long as the run lasts, and the `hash-file` and `upload-asset` tasks it queues hold more. On a phone that chain has to fit inside `EnginePool.POOL_SIZE`. It used to be worse: a separate `auto-import` task sat in a slot of its own for as long as the setting was on, and started an `import-assets` in a second slot, which is what deadlocked the pool at three, silently, with the setting on, the task running and the counts at zero forever. That task is gone and the run now ends, but the pool is still sized for the chain that remains. See [Mobile background tasks](mobile-background-tasks.md) before changing anything about that.

## While the app is not on screen

The loop that starts one pass after another lives on the native side of the mobile apps, not in the WebView. It used to be a `setInterval` in the WebView, and that is exactly why automatic import stopped the moment the app was backgrounded: the operating system throttles and then stops a WebView's timers, and photos taken after that were backed up only when the app was next opened, with nothing anywhere saying so. Nothing in the WebView queues an import on any platform now.

Syncing works the same way and for the same reason, in a loop of its own beside this one, so a photo imported while the app is off screen reaches the remote without the app being opened. [Syncing](syncing.md) describes that half: what it costs to ask whether there is anything to push, the two settings and where they live, and what the two loops contend on when their passes overlap.

The settings moved for the same reason. They used to be in the WebView's `localStorage`, which nothing outside the WebView can read, so a service that woke up had no way to find out whether automatic import was switched on or what it should be reading. They live in `auto-import.toml` in the app's storage sandbox, beside `databases.toml`.

The native side does not parse that file. It asks the `plan-auto-import` worker task, which reads the settings, decides whether a pass should run, and hands back the tasks the pass consists of, already built: `create-database` and `record-default-database` the first time, and `import-assets` every time. Native code forwards each one to the engine pool unchanged and never assembles a payload of its own, so what a pass does is decided once, in TypeScript, and cannot drift between the two platforms.

What differs between them is only what keeps the loop alive:

| | Android | iOS |
|---|---|---|
| While the app is on screen | Keeps importing | Keeps importing |
| While the app is backgrounded | Keeps importing, in a foreground service | The system runs a pass when it chooses |
| While the screen is off | Keeps importing, holding a wake lock for the length of a pass | The system runs a pass when it chooses |
| What the user sees | An ongoing notification for as long as automatic import is on | Nothing |

**On Android** it is a foreground service (`AutoImportService`), which hosts the sync loop as well as this one, on a thread each, under the one notification and the one wake lock. Sharing a service is not sharing a switch: either feature being on runs it, switching one off leaves the other running, and it stops when neither is on. The platform refuses to start a foreground service for an app that is not itself in the foreground, which an app launched behind a lock screen is not, so a refusal is caught and the service asked for again when the app resumes. Uncaught, that exception killed the app outright every time it was opened with automatic import already on. The platform requires a foreground service to post an ongoing notification, so switching automatic import on means a permanent notification while it is on: that is a visible product change and not something the app can opt out of. A second service for syncing would mean a second notification for one feature, which is why there is not one. The service holds a `PARTIAL_WAKE_LOCK` only while a pass is actually running and releases it in between, because a foreground service keeps the process alive but does not by itself keep the CPU awake once the screen is off, and a lock held all night flattens the phone.

**On iOS** the loop runs while the app is foregrounded, and what happens when it is not is the system's decision. The app registers a `BGProcessingTask` and asks for one after each pass; iOS runs it when it sees fit, typically while the phone is charging and idle, and may kill it part way. The honest description is that iOS catches up when the system allows, not that it backs up continuously, and the settings card says so. A phone in a pocket all day may import nothing until the app is opened. There is no way round that short of doing the work on a server rather than on the phone, which is a different feature.

Two passes at once is unreachable rather than unlikely. There is one driver for the life of the app, with one entry point that runs a pass, and it is serialised: asked to run while a pass is in flight, it waits for that pass and returns its outcome rather than starting a second. On Android only the service's loop asks; on iOS both the foreground loop and the system's background task do, and neither knows about the other because neither has to.

An import pass and a sync pass do overlap, and have to. A first backup of a whole photo library is one import pass lasting the better part of an hour, and syncing has to push what that pass has already imported rather than wait for the end of it. The two contend only on the database write lock, which neither holds for a whole pass: an import takes it per batch of imported assets, and a sync takes it around its pull and again around its push. See [Syncing](syncing.md) for what that means for a sync that finds the lock held.

All of it is opt-in and stays opt-in. Until the user switches automatic import on there is no service, no background task request, no wake lock, no notification and no permission prompt, and switching it off takes all of them away again: the Android service stops and its notification goes with it, and the iOS background request is withdrawn.

One more thing had to change for any of this to work: the engine pool used to be torn down when the WebView was destroyed, which is precisely when the service needs it. It is now torn down by whichever of the two goes last.

## Tests

Unit tests sit beside the code under `src/test/`. The end-to-end behaviour is covered by CLI smoke tests:

| Test | What it proves |
|---|---|
| `81-watch-once` (`psi add`) | A pass imports what is there, and a second pass imports nothing twice. |
| `82-watch-continuous` (`psi add --watch`) | A file created while the command is running is imported, and Ctrl-C stops it. |
| `83-watch-cleanup` | A source file the database holds is deleted and one that failed to import is not. |
| `84-watch-sync-evict` | Imports reach the origin once `psi sync` pushes them, and the local originals stay. Eviction is no longer something the CLI can turn on, so it is covered by its unit tests rather than here. |
| `85-consolidate` | Creating a remote, consolidating into an unrelated one without duplicating shared content, and sync working afterwards where it refused before. |
| `86-multi-device` | Two databases connected to one remote each end up with the other's photos. |
| `87-import-record` | What a database imported is remembered across restarts, manual and automatic imports are badged apart, the record is written outside the database in this machine's cache directory, two databases on one machine each get their own, and no `imports.dat` appears inside a database directory after sync, consolidation or replication. |

And by Electron smoke tests, which drive the real app:

| Test | What it proves |
|---|---|
| `35-auto-import` | Switching the toggle on creates the default private database, lists it with the default badge, imports a photo dropped into a watched folder with nothing else done, deletes the source file once the cleanup toggle is on, and shows what the database imported when the app is closed and reopened. |
| `36-consolidate-database` | Only one database can be the default, and consolidating into an unrelated remote through Manage Databases uploads only what the remote does not have and leaves ordinary sync working. |

And by a mobile smoke test, which drives the real app on an Android emulator:

| Test | What it proves |
|---|---|
| `47-auto-import` | A photo put into the device photo library from outside the app is imported with nothing else done: the app makes its own default database, walks the library, and imports it. A second photo put there while the app is running is noticed and imported too, the Import page shows the count, and the photo lands in the gallery without the database being reopened. |
| `48-auto-import-no-permission` | Switching the toggle on without the photo permission switches it back off, says why, and creates no database. The permission is refused from outside the app by revoking it and marking it user-fixed, which is what Android does when a user chooses "Don't allow" and means it, so the request is answered without a dialog a test cannot tap. |
| `49-background-import` | A photo put into the device library while the app is backgrounded is imported, and so is one put there while the screen is off. Both are measured by counting originals in the database on disk through `run-as` rather than by anything the app says, because a backgrounded WebView may have its socket to the harness suspended, which is the exact moment the test cares about. It also checks the foreground service is running throughout and gone once the toggle is switched off. |

Those are Android only. The iOS simulator has no supported way to remove a seeded photo, and a test that leaves one behind poisons every run after it. What test 49 covers is untestable on iOS for a second reason as well: a `BGProcessingTask` is scheduled by the system and the only way to force one is an lldb command against a running app, which this harness cannot issue on Xcode 14.2. That gap is written down in `apps/smoke-tests/tests/49-background-import/IOS-NOT-COVERED.md` rather than left as an absence nobody notices.

Test 47 is the one that caught the engine-pool deadlock, and the one that would catch it again. It waits for the photo to arrive rather than for the task to start, because a deadlocked import looks exactly like a working one from outside: the setting is on, the task is running, and the counts sit at zero forever.

Writing those two found three further defects that nothing else had:

- The photo permission request never delivered its answer. It went straight to `ActivityCompat.requestPermissions`, whose result reaches the Activity, and Capacitor only forwards a result to the plugin it believes made the request, so a request it never saw was answered into nothing and the call waited forever. It now asks through Capacitor's own permission API, under an alias declared on the plugin.
- An automatically imported photo appeared in the gallery twice, because the import task announced it as `import-success` and the automatic import loop announced it as `auto-import-item`, and the gallery appended both. The two messages have since been merged into one `import-success` that both kinds of import send, so there is nothing left to announce twice. The list still refuses an asset it already holds, which covers a photo taken in before the database has finished loading.
- An arrival landed in whatever gallery was open, not the database it went into. Automatic import writes to the default database, which is not necessarily the one on screen. Every arrival now names its database and the gallery ignores the ones that are not its own.
