# Automatic photo backup

Photosphere can watch where photos arrive, import them on its own, and push them to a remote copy. This describes the engine that does it, the command that drives it today, and what each platform can and cannot do.

## What it does

Point Photosphere at one or more places where photos turn up and it will:

- import anything that is already there, slowly, so backfilling years of photos does not make the machine unusable;
- import anything new the moment it appears;
- push what it imported to a remote database, when one is configured;
- optionally delete the source file once the photo is confirmed in the local database;
- optionally drop local originals the remote already holds, so the local database can stay small.

Nothing about the import itself is new. Every batch the engine decides on is handed to the existing `import-assets` task, so deduplication by content hash, the write lock, derivative generation and the hash cache all behave exactly as they do for a manual `psi add`.

## The command

```bash
psi watch --db ./photos                       # watch this operating system's photo folders
psi watch --db ./photos ~/Pictures ~/Camera   # watch specific folders
psi watch --db ./photos --once                # import everything once, then exit
psi watch --db ./photos --cleanup             # delete each source file once it is in the database
psi watch --db ./photos --evict               # drop local originals the origin already holds
psi watch --db ./photos --no-sync             # import without syncing to the origin
```

With no folders given it watches the operating system's own photo locations: `Pictures` and `Pictures\Camera Roll` on Windows, `Pictures` on macOS, and the XDG pictures directory (falling back to `~/Pictures`) on Linux. Only folders that actually exist are watched.

`--once` does a single pass and exits, and exits non-zero if any file failed to import or if a sync it was asked to do failed. That is what makes it usable from a scheduler: a backup that did not happen must not look like one that did.

Without `--once` it runs until interrupted. Ctrl-C stops it.

## The two lanes

Media is imported through two lanes, which is what keeps a photo you have just taken from queueing behind ten years of backfill.

The **fast lane** carries items that appeared since the task started. It is released in full the moment it is asked for.

The **backfill lane** carries the library that already existed. It is released at a fixed rate, 60 items per minute by default. The budget is capped at one minute's worth, so a task that sat idle for an hour does not then release an hour's allowance at once.

Where the backfill has reached is written into the database's state file, so restarting resumes rather than walking the whole library again. The position only moves once every item of a page has been imported, so a crash mid-page re-offers a handful of items rather than losing them. Re-offering is harmless: the import deduplicates by content hash.

## Watching, and why there is also a poll

Each source both watches and polls. The poll is not a belt-and-braces extra: recursive directory watching is not available on Linux at all, and is not dependable across network and removable filesystems anywhere. The poll is what actually guarantees a new photo is noticed. It runs every 30 seconds by default.

On every reported change the whole source listing is walked, and anything the queue has not seen before is queued. That is deliberately thorough rather than clever: a watcher that describes what changed is not something every platform can be trusted to provide.

## Deleting the source file

`--cleanup` deletes a source file once the photo is confirmed in the local database. Confirmation means the database itself holds a file with that content hash, not that the import reported success. A file the import failed on is never deleted, and neither is one whose hash is not in the database.

A file the database already held counts as confirmed too, so a source file is not left behind and re-offered on every poll for as long as the app runs.

This is off by default, and deliberately so: it has nothing to do with the remote. A user with cleanup on and no remote connected is trusting a single local copy.

## Dropping local originals

Once a local database is connected to a remote it is a partial replica of it, which means it does not have to keep every original on the device: an original the remote holds can be fetched back when it is wanted.

`--evict` drops those originals after each successful sync. Only the original and the transcoded display copy go; the thumbnail and the micro thumbnail stay, which is what keeps the gallery browsable with no network at all. An original the origin does not hold with a matching hash is never dropped, whatever else is going on.

Which originals go is decided by a retention policy. Four are implemented, exported and unit tested in `packages/api/src/lib/retention-policy.ts`:

| Policy | What it keeps |
|---|---|
| `SizeBudgetRetentionPolicy` | Local originals under a byte cap, dropping the oldest confirmed first. |
| `RecentDaysRetentionPolicy` | Originals imported within the last N days. |
| `FreeSpaceRetentionPolicy` | Enough free space on the device, dropping the oldest confirmed until there is. |
| `DropWhenConfirmedRetentionPolicy` | No confirmed originals at all: the smallest possible local database. |

The active one is `ACTIVE_RETENTION_POLICY` at the bottom of that file, set to a two gigabyte size budget. The other three are written out directly beneath it and commented out, so switching policy is uncommenting one line.

`--evict-budget <bytes>` overrides the cap for one run without changing the code, which is also what lets the smoke tests exercise eviction with ordinary-sized photos rather than needing more than two gigabytes of test data.

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

Every import, whether the user asked for it or it arrived on its own, is written to the database's own import record at `.db/imports.dat`. The Import page shows it, newest first, so opening a database answers "what came in?" rather than only showing what has happened since the app started. Each row is badged **manual** or **automatic**, because a photo that arrived on its own is the one a user is most likely to be asking about.

The record holds the last 1000 imports. When it is full the oldest go and the page says so, rather than presenting a partial history as a complete one.

**It never travels.** It is written straight to storage and is deliberately not added to the merkle tree, which is what keeps it out of sync, replication and consolidation: those copy what the tree indexes. It is this machine's account of what it did, not part of the photo collection, and a record that quietly travelled would show one machine's imports as another's. `87-import-record` proves it stays put while the photos themselves go.

Losing it costs nothing but the history: an unreadable record reads as empty, and a record that cannot be written does not fail the import, because by then the photos are already in the database.

## What each platform can do

| | CLI | Desktop | Mobile |
|---|---|---|---|
| Watch folders | Yes | Yes | Not applicable |
| Watch the device photo library | No | No | Yes |
| Backfill pacing, cleanup, eviction | Yes | Yes | Yes |
| Consolidation | Yes | Yes | No |

The engine is platform-neutral and lives in `packages/api`, with the Node-side parts in `packages/node-api`. The only platform-specific part is the media source: `FolderMediaSource` covers folders on a filesystem and `DeviceMediaSource` covers the device photo library. The loop itself talks only to `IMediaSource` and knows about neither.

On the desktop the settings live on the configuration dialog and the settings page: a toggle, the folders being watched, and whether the source file is deleted after import. Switching the toggle on creates a private photo database under the application data directory, lists it as "My Photos" and marks it as the one automatic import writes to. The main process starts and stops the task as the settings change, so nothing needs restarting.

On mobile the same thing happens and the user does the same thing: switch the toggle on, and the app makes its private database, asks for the photo permission, walks the device photo library and imports what it finds, including photos taken while it is running. It runs the same `auto-import` task the CLI and the desktop run, reading the photo library through the same host bridge the rest of the worker code uses. The only difference is which media source is registered underneath.

That task holds an engine slot for as long as automatic import is on, and the `import-assets` task it queues holds another, and the `hash-file` and `upload-asset` tasks that import queues in turn hold more. On a phone that chain has to fit inside `EnginePool.POOL_SIZE`, which is why the pool is five rather than three: at three it deadlocked, and the failure was silent, with the setting on, the task running and the counts at zero forever. See [Mobile background tasks](mobile-background-tasks.md) before changing anything about that.

## Where the code is

| File | What it holds |
|---|---|
| `packages/api/src/lib/auto-import-settings.ts` | The settings, and the normalisation that makes a hand-edited settings blob safe to read. |
| `packages/api/src/lib/retention-policy.ts` | The four retention policies and the active one. |
| `packages/node-utils/src/lib/photo-folders.ts` | The operating system's photo folders. |
| `packages/api/src/lib/auto-import-loop.ts` | The loop itself, with nothing platform-specific in it. |
| `packages/api/src/lib/media-source.ts` | The source abstraction the loop reads through. |
| `packages/api/src/lib/auto-import-queue.ts` | The two lanes and the pacing, with no I/O in it at all. |
| `packages/api/src/lib/source-cleanup.ts` | Choosing and deleting confirmed source files. |
| `packages/api/src/lib/import-record.ts` | What a database imported, capped and newest first. |
| `packages/node-api/src/lib/import-record-storage.ts` | Reading and writing that record, deliberately outside the merkle tree so it never travels. |
| `packages/node-api/src/lib/get-import-record.worker.ts` | Reading it for the interface, which cannot open the database itself. |
| `packages/node-api/src/lib/media-source-registry.ts` | How a platform registers the source kinds it can serve. |
| `packages/node-api/src/lib/folder-media-source.ts` | Folders on a filesystem, watched and polled. |
| `packages/node-api/src/lib/auto-import.worker.ts` | The task every platform runs it from. |
| `packages/node-api/src/lib/evict-originals.worker.ts` | Dropping local originals the origin holds. |
| `packages/node-api/src/lib/consolidate.ts` | Joining a standalone database to a remote that already has content. |
| `packages/node-api/src/lib/auto-import-desktop.ts` | What the desktop app should do about automatic import, worked out from its config. |
| `packages/user-interface/src/lib/auto-import-config.ts` | Reading and writing the settings through the app's config store. |
| `packages/user-interface/src/components/auto-import-settings.tsx` | The "Automatic import" card. |
| `packages/user-interface/src/components/consolidate-database-dialog.tsx` | Joining a database to a remote so the two can sync. |
| `packages/mobile-worker/src/lib/device-media-source.ts` | The device photo library as a media source. |
| `packages/mobile-worker/src/shims/media-library.ts` | Typed access to the native photo library host functions. |
| `packages/mobile-frontend/src/lib/mobile-media-permission.ts` | What to do when the photo permission is refused. |
| `packages/mobile-frontend/src/lib/mobile-media-cleanup.ts` | Batching the device deletes the system asks the user to confirm. |
| `apps/android-frontend/.../jsengine/MediaLibrary.java`, `MediaLibraryHost.java` | The Android photo library: paging, copying out and delete over `MediaStore`. |
| `apps/android-frontend/.../jsengine/MediaPermissions.java`, `MediaDeleteBroker.java` | The per-version photo permission, and the staged delete confirmation. |
| `apps/ios-frontend/.../MediaLibrary.swift`, `MediaLibraryHost.swift` | The same for iOS, over the Photos framework. |
| `apps/cli/src/cmd/watch.ts`, `apps/cli/src/cmd/connect.ts` | The two commands. |

## Tests

Unit tests sit beside each of those files under `src/test/`. The end-to-end behaviour is covered by CLI smoke tests:

| Test | What it proves |
|---|---|
| `81-watch-once` | A pass imports what is there, and a second pass imports nothing twice. |
| `82-watch-continuous` | A file created while the command is running is imported, and Ctrl-C stops it. |
| `83-watch-cleanup` | A confirmed source file is deleted and one that failed to import is not. |
| `84-watch-sync-evict` | Imports reach the origin, confirmed originals are dropped, thumbnails stay, and the dropped original is fetched back from the origin on demand. |
| `85-consolidate` | Creating a remote, consolidating into an unrelated one without duplicating shared content, and sync working afterwards where it refused before. |
| `86-multi-device` | Two databases connected to one remote each end up with the other's photos. |
| `87-import-record` | What a database imported is remembered across restarts, manual and automatic imports are badged apart, and the record never travels: sync, consolidation and replication all leave `.db/imports.dat` behind while the photos themselves go. |

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

Both are Android only. The iOS simulator has no supported way to remove a seeded photo, and a test that leaves one behind poisons every run after it.

Test 47 is the one that caught the engine-pool deadlock, and the one that would catch it again. It waits for the photo to arrive rather than for the task to start, because a deadlocked import looks exactly like a working one from outside: the setting is on, the task is running, and the counts sit at zero forever.

Writing those two found three further defects that nothing else had:

- The photo permission request never delivered its answer. It went straight to `ActivityCompat.requestPermissions`, whose result reaches the Activity, and Capacitor only forwards a result to the plugin it believes made the request, so a request it never saw was answered into nothing and the call waited forever. It now asks through Capacitor's own permission API, under an alias declared on the plugin.
- An automatically imported photo appeared in the gallery twice, because the import task announces it as `import-success` and the automatic import loop announces it as `auto-import-item`, and the gallery appended both. The list now refuses an asset it already holds.
- An arrival landed in whatever gallery was open, not the database it went into. Automatic import writes to the default database, which is not necessarily the one on screen. Every arrival now names its database and the gallery ignores the ones that are not its own.
