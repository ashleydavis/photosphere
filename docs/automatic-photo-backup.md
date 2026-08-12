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

Sync refuses to run between two databases that are not related to each other, and this feature does not weaken that refusal. `psi connect` is the separate, explicit operation that makes them related:

```bash
psi connect --db ./photos ./backup                  # a directory
psi connect --db ./photos s3:my-bucket:/photos      # an S3 location
```

It looks at what is there and picks between three cases:

- **Nothing at the remote path.** The remote is created as a copy of this database, which carries the database id across, and the origin is recorded.
- **A database that is not related.** The two are consolidated. Local content the remote does not have, compared by content hash rather than by asset id, is pushed to it. Content the remote already holds is not pushed a second time, whatever id it has there. The local database then becomes a partial replica of the remote: it adopts the remote's database id, records it as its origin, takes on the remote's records and thumbnails, and is marked partial.
- **A database that is already related.** The origin is recorded and nothing moves.

After any of the three, ordinary `psi sync` works.

Two machines each connected to the same remote end up with each other's photos: each pushes what the remote does not have, and each pulls the rest.

## What each platform can do

| | CLI | Desktop | Mobile |
|---|---|---|---|
| Watch folders | Yes | Yes | Not applicable |
| Watch the device photo library | No | No | Yes |
| Backfill pacing, cleanup, eviction | Yes | Yes | Yes |
| Consolidation | Yes | Yes | No |

The engine is platform-neutral and lives in `packages/api`, with the Node-side parts in `packages/node-api`. The only platform-specific part is the media source: `FolderMediaSource` covers folders on a filesystem and `DeviceMediaSource` covers the device photo library. The loop itself talks only to `IMediaSource` and knows about neither.

On the desktop the settings live on the configuration dialog and the settings page: a toggle, the folders being watched, and whether the source file is deleted after import. Switching the toggle on creates a private photo database under the application data directory, lists it as "My Photos" and marks it as the one automatic import writes to. The main process starts and stops the task as the settings change, so nothing needs restarting.

On mobile the same thing happens, and the user does the same thing: switch the toggle on, and the app makes its private database, asks for the photo permission, walks the device photo library and imports what it finds, including photos taken while it is running.

One thing is arranged differently, and it matters. The loop runs in the WebView rather than in a worker task. The embedded engine pool has three slots (`EnginePool.POOL_SIZE`); the asset server holds one for the life of the app, so a long-running orchestrator task in a second slot leaves nothing for the tasks the import it queues needs in turn, and the import waits for a slot that can never come free. That is not a theory: the task started, handed over one batch, and nothing ever completed. Driven from the WebView the loop occupies no slot, and the import it queues behaves exactly as a manual import does.

That is why the loop itself lives in `packages/api` as `runAutoImportLoop`, with the CLI and the desktop driving it from the `auto-import` task and mobile driving it from `MobileAutoImportScheduler`. One loop, two drivers, rather than two implementations that drift apart. It is also why mobile reads the photo library through the Capacitor plugin's `mediaLibrary*` methods rather than through the engine's host bridge: same native code, called from the side that is doing the work. Nothing inside an engine reads the photo library, deliberately.

Two things a WebView cannot do are passed into the loop instead: running the import (the `import-assets` task, as everywhere else) and reading the database's content hashes (the `get-content-hashes` task, which is what confirms a photo is safe to delete off the device). Where the backfill has reached is kept in the app's own config rather than in the database state, because the WebView cannot take the write lock; losing it costs time and nothing else, since the import recognises what it already holds by content hash.

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
| `packages/node-api/src/lib/media-source-registry.ts` | How a platform registers the source kinds it can serve. |
| `packages/node-api/src/lib/folder-media-source.ts` | Folders on a filesystem, watched and polled. |
| `packages/node-api/src/lib/auto-import.worker.ts` | The task the CLI and the desktop drive the loop from. |
| `packages/node-api/src/lib/get-content-hashes.worker.ts` | What the database holds, for a caller that cannot open its storage. |
| `packages/node-api/src/lib/evict-originals.worker.ts` | Dropping local originals the origin holds. |
| `packages/node-api/src/lib/consolidate.ts` | Joining a standalone database to a remote that already has content. |
| `packages/node-api/src/lib/auto-import-desktop.ts` | What the desktop app should do about automatic import, worked out from its config. |
| `packages/user-interface/src/lib/auto-import-config.ts` | Reading and writing the settings through the app's config store. |
| `packages/user-interface/src/components/auto-import-settings.tsx` | The "Automatic import" card. |
| `packages/user-interface/src/components/connect-database-dialog.tsx` | Connecting a database to a remote. |
| `packages/mobile-frontend/src/lib/mobile-auto-import-scheduler.ts` | What mobile drives the loop from, in the WebView. |
| `packages/mobile-frontend/src/lib/device-media-source.ts` | The device photo library as a media source. |
| `packages/mobile-frontend/src/lib/device-media-library.ts` | Reading the photo library through the Capacitor plugin. |
| `packages/mobile-frontend/src/lib/mobile-backfill-cursor.ts` | Where the backfill has reached, kept in the app's config. |
| `packages/mobile-frontend/src/lib/mobile-media-permission.ts` | What to do when the photo permission is refused. |
| `packages/mobile-frontend/src/lib/mobile-media-cleanup.ts` | Batching the device deletes the system asks the user to confirm. |
| `apps/android-frontend/.../jsengine/MediaLibrary.java`, `MediaLibraryHost.java` | The Android photo library: paging, export and delete over `MediaStore`. |
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
| `85-connect` | Creating a remote, consolidating into an unrelated one without duplicating shared content, and sync working afterwards where it refused before. |
| `86-multi-device` | Two databases connected to one remote each end up with the other's photos. |

And by Electron smoke tests, which drive the real app:

| Test | What it proves |
|---|---|
| `35-auto-import` | Switching the toggle on creates the default private database, lists it with the default badge, imports a photo dropped into a watched folder with nothing else done, and deletes the source file once the cleanup toggle is on. |
| `36-connect-database` | Only one database can be the default, and connecting to an unrelated remote through Manage Databases uploads only what the remote does not have and leaves ordinary sync working. |

And by a mobile smoke test, which drives the real app on an Android emulator:

| Test | What it proves |
|---|---|
| `47-auto-import` | A photo put into the device photo library from outside the app is imported with nothing else done: the app makes its own default database, walks the library, and imports it. A second photo put there while the app is running is noticed and imported too, the Import page shows the count, and the photo lands in the gallery without the database being reopened. |
| `48-auto-import-no-permission` | Switching the toggle on without the photo permission switches it back off, says why, and creates no database. The permission is refused from outside the app by revoking it and marking it user-fixed, which is what Android does when a user chooses "Don't allow" and means it, so the request is answered without a dialog a test cannot tap. |

Both are Android only. The iOS simulator has no supported way to remove a seeded photo, and a test that leaves one behind poisons every run after it.

Test 47 is the one that would have caught the engine-pool deadlock. It waits for the photo to arrive rather than for the task to start, because a deadlocked import looks exactly like a working one from outside: the setting is on, the loop is running, and the counts sit at zero forever.

Writing those two found three further defects that nothing else had:

- The photo permission request never delivered its answer. It went straight to `ActivityCompat.requestPermissions`, whose result reaches the Activity, and Capacitor only forwards a result to the plugin it believes made the request, so a request it never saw was answered into nothing and the call waited forever. It now asks through Capacitor's own permission API, under an alias declared on the plugin.
- An automatically imported photo appeared in the gallery twice, because the import task announces it as `import-success` and the automatic import loop announces it as `auto-import-item`, and the gallery appended both. The list now refuses an asset it already holds.
- An arrival landed in whatever gallery was open, not the database it went into. Automatic import writes to the default database, which is not necessarily the one on screen. Every arrival now names its database and the gallery ignores the ones that are not its own.
