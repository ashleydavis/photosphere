# Syncing

A Photosphere database can be connected to a remote copy of itself, and syncing is what keeps the two the same. This describes what a sync does, how it works out whether there is anything to do, what it costs to ask, when each platform runs one, and what happens while the app is not on screen.

## What it does

A sync is two-way between a local database and its origin. It pulls what the origin has and the local database does not, then pushes what the local database has and the origin does not, and stamps both sides as synced. When it finishes, both hold the same content: the same records, the same thumbnails, and the same originals, except where the local database is a partial replica that has dropped originals the origin holds.

Because it is two-way, two phones and a desktop connected to one remote end up with each other's photos. Each pushes what the remote does not have and pulls the rest.

What it moves is decided by comparing merkle trees rather than by remembering what was sent last time. There is no queue of pending uploads anywhere, and nothing has to be replayed after a crash: a sync interrupted half way leaves both databases valid, and the next one works out what is still missing by looking.

**Importing and syncing are separate operations, deliberately.** An import takes photos in from a folder or the device photo library and writes them to the local database. A sync moves what is in the local database to the origin, and knows nothing about where any of it came from. `psi add --watch` and `psi sync --watch` are two commands for that reason, and the mobile app runs two background loops for the same reason. Merging them would make each half untestable without the other, and neither is useful only in company: a database with no origin still imports, and a database nothing imports into still syncs edits.

## It refuses to sync unrelated databases

Sync moves content between two databases that are copies of each other. It will not run between two that are not, because there is no correct answer to what should happen: the content of two unrelated databases merged by asset id is neither database.

`psi consolidate` is the separate, explicit operation that relates them, and it records the origin in the local database's config as it goes. See [Automatic photo backup](automatic-photo-backup.md) for what consolidation does in each of the cases it handles.

So a database with no origin recorded is not a failure and is not reported as one. Sync skips it and says why, which is what a database nobody has connected to a remote looks like.

## How it knows whether there is anything to do

Each database keeps a small state file holding the content hash of everything in it. A sync reads both, and if the two hashes are equal the databases are identical and it stops there: no write lock is taken on either side, and no merkle tree is downloaded.

That early-out is what makes running a sync over and over affordable, and it is why nothing has to keep track of whether the database has changed since the last sync. Asking is cheap enough to be the whole mechanism.

The state files are also what the two sides stamp when a sync completes, so a sync that ran leaves both hashes equal and the next one early-outs.

## What a pass costs

There are two costs, and they are far apart.

- **Nothing to do.** Two small file reads, one of them at the origin. On an S3 origin that is a single small object fetched over the network. This is what almost every pass costs on a phone that is sitting still.
- **Something to do.** The write lock at each side, the merkle trees loaded and compared, and then the records and files that differ, transferred.

The second cost is proportional to what changed rather than to the size of the database, which is what makes a frequent sync cheaper than a rare one: the same work is done either way, in smaller pieces.

The consequence to know about is that the cheap case is not free. A pass over a metered connection is a small network request, and a loop that asked every few seconds would spend a phone's battery and data allowance finding out that nothing had happened. That is what sets the gap between passes, not the cost of the sync itself.

## The command

```bash
psi sync --db ./photos                          # push and pull once, then exit
psi sync --db ./photos --watch                  # keep syncing, every thirty seconds
psi sync --db ./photos --watch --interval 300   # keep syncing, every five minutes
```

`psi sync` without `--watch` runs one sync and exits, and says whether it moved anything. That is what makes it usable from a scheduler.

With `--watch` it runs the same sync over and over until interrupted. A sync that fails is reported and the watch carries on, because a network that is down now may be up in thirty seconds and stopping would mean nothing syncs again until somebody notices.

Run it beside `psi add --watch` to get both halves. Each is separately useful and separately testable.

## When a sync runs

| | What starts one |
|---|---|
| CLI | Nothing, unless asked. `psi sync` runs one; `psi sync --watch` runs them on an interval. |
| Desktop | The main process: a debounced sync ten seconds after the open database is edited, and one every five minutes regardless. |
| Mobile | A native loop, one pass at a time with a gap in between, running whether or not the app is on screen. An edit made in the app also starts one, once, at the moment it happens. |

The desktop's debounce is what makes an edit reach the remote promptly without a sync per keystroke: rapid edits coalesce into one.

Mobile has no debounce and nothing periodic in the app. The loop that runs one pass after another is native, and the only sync the app itself starts is the one after an edit: no timer, no interval, just the database that edit was made in, synced once. That is what stops an edit sitting on the phone until the loop's next pass, and it is the only way a database the user opened by hand reaches its origin at all, because the native loop pushes a different one (see below).

## The two settings

Two toggles on the configuration dialog control automatic syncing, on every platform:

| Setting | What it does | Default |
|---|---|---|
| **Enable syncing** | The master switch. Off means no automatic sync runs at all. | On |
| **Only sync over Wi-Fi** | Refuses an automatic sync while the connection is cellular. | On |

Neither affects a sync the user asks for explicitly, and neither affects the CLI, which syncs when the command says to.

**On mobile they live in `sync.toml`** in the app's storage sandbox, beside `databases.toml` and `auto-import.toml`. They used to be in the WebView's config store, which nothing outside the WebView can read, and a loop that runs while the app is off screen has to be able to find out whether syncing is switched on at all. It is a separate file from `auto-import.toml` because they are separate features: switching automatic import off must not switch syncing off, and a user reading one of those files should not find the other feature's settings in it.

The file holds the two toggles and the gap between passes:

```toml
enabled = true
only_on_wifi = true
pause_between_runs_ms = 300000
```

A gap of zero, a negative gap, or anything that is not a number falls back to the default, because a gap of zero is a loop with no gap at all.

**A file that is missing or will not parse reads as syncing switched off.** That is the opposite of what the toggle defaults to in a fresh install, and deliberately: the app writes the file as soon as the settings are touched, so an unreadable one means something is wrong, and the safe answer to "should this phone start pushing over its cellular connection?" when nothing can be read is no.

On the desktop the same two settings are held by the main process in `desktop.toml`, where they have always been. Nothing outside the app needs to read them there, because the loop that uses them is in the same process.

## When a sync is refused

Every automatic sync, on every platform, is decided by one function: `computeSyncAllowed` in `packages/api/src/lib/sync-gate.ts`. It refuses when

- syncing is switched off;
- the device is offline;
- the connection type is `none`;
- the Wi-Fi-only restriction is on and the connection type is `cellular`.

A connection type of `unknown` is permitted, including under the Wi-Fi-only restriction. The desktop and the browser cannot tell a cellular connection from any other, so they report `unknown`, and treating that as cellular would make the Wi-Fi-only setting mean "never sync" everywhere but a phone.

There is one implementation of that rule and both callers use it: the app's own interface, and the mobile background loop. A second copy would be a second thing to keep in step, and the failure when they drift is somebody's mobile data bill.

The mobile background loop cannot ask the WebView what the connection is, because there may be no WebView. It asks the native side directly, through a host function that reports `wifi`, `cellular`, `none` or `unknown` from `ConnectivityManager` on Android and `NWPathMonitor` on iOS. Anything the platform reports that does not map onto those comes back as `unknown` rather than throwing, so a connection nobody anticipated does not stop syncing.

## What gets synced in the background on mobile

The database automatic import writes to, and only that one. It is the database that gains photos while the app is off screen, which is the whole point of syncing in the background, and its path is recorded in `auto-import.toml` where the native side can already read it.

Three consequences follow, and all three are limits rather than oversights:

- A phone with no default database recorded syncs nothing in the background. There is nothing to sync: the default database is created the first time automatic import runs.
- A database opened by hand in the app is not pushed by the background loop, even when it has an origin. An edit made in it is synced at the moment it is made, and that is the whole of it: nothing pushes it on a timer, and nothing pushes it once the app is off screen.
- **Background syncing on mobile runs only while automatic import is on.** The two loops live in one Android foreground service and start and stop together, because the platform requires a service to post an ongoing notification and a second service would mean a second notification for one feature. A phone with automatic import switched off syncs when the app is open and an edit is made, and not otherwise.

## While the app is not on screen

The loop that runs one sync pass after another lives on the native side of the mobile apps, not in the WebView, for the same reason the import loop does: the operating system throttles and then stops a WebView's timers once the app is backgrounded, so a phone that imported photos in the background pushed none of them until somebody opened the app. Nothing in the WebView starts a sync on any platform now.

The native side holds no decisions. It asks the `plan-sync` worker task whether a sync should run, and that task reads the settings file, asks for the connection type, applies the same rule the interface applies, checks the database has an origin, and hands back the `sync-database` task to queue, already built. Native code forwards it unchanged and never assembles a task payload of its own, so what a pass does is decided once, in TypeScript, and cannot drift between the two platforms.

A refused pass never ends the loop, which is the one way the sync loop differs from the import loop. Every reason to refuse a sync can go away without the app being touched: a phone moves onto Wi-Fi, a network comes back, a database gets an origin, the user switches syncing on again. A loop that ended on a refusal would need something to notice each of those and start it again, and a loop nobody restarted is the silent kind of broken this app has been bitten by before. A refused pass costs one settings file read.

What differs between the platforms is only what keeps the loop alive:

| | Android | iOS |
|---|---|---|
| While the app is on screen | Keeps syncing | Keeps syncing |
| While the app is backgrounded | Keeps syncing, in the same foreground service that runs the import | The system runs a pass when it chooses |
| While the screen is off | Keeps syncing, holding a wake lock for the length of a pass | The system runs a pass when it chooses |
| What the user sees | The one ongoing notification automatic import already posts | Nothing |

**On Android** the sync loop runs on its own thread inside `AutoImportService`, the foreground service automatic import already uses. There is deliberately not a second service: a second service means a second ongoing notification for one feature, which is a visible product change nobody asked for. The two loops start and stop together with the service, under the one notification and the one wake lock, and the lock is held only while a pass is actually running, because a lock held all night flattens the phone.

**On iOS** the loop runs while the app is foregrounded, and what happens when it is not is the system's decision. The app registers a `BGProcessingTask` for sync beside the one for import and asks for another after each pass. iOS runs them when it sees fit, typically while the phone is charging and idle, and may kill one part way. The honest description is that iOS catches up when the system allows, not that it syncs continuously. A phone in a pocket all day may push nothing until the app is opened.

Two sync passes at once is unreachable rather than unlikely, by the same construction the import driver uses: one driver for the life of the app, with one entry point that runs a pass, serialised so that asking while a pass is in flight waits for that pass and returns its outcome rather than starting a second. On Android only the service's loop asks; on iOS the foreground loop and the system's background task both do, and neither knows about the other.

It is all opt-in and stays opt-in. Switching syncing off stops the loop, and on iOS the background request is withdrawn rather than left with the system.

## A sync and an import never overlap

An import pass holds the database write lock for as long as it runs, and it holds engine slots: `import-assets` holds one for the whole run and the `hash-file` and `upload-asset` tasks it queues hold more, all inside `EnginePool.POOL_SIZE`. A sync started in the middle of one would sit in a slot of its own waiting for a write lock the import is not going to release for a while, which is the arrangement that once deadlocked the pool silently, with the feature switched on and the counts at zero forever. See [Mobile background tasks](mobile-background-tasks.md) for what a slot is and why running out is a hang rather than a slowdown.

So the two background loops take a single lock around a pass, and a loop that cannot take it skips its pass and tries again after its usual gap. Skipping rather than waiting is what keeps a sync from queueing behind a long import: a first backup of a whole photo library takes the better part of an hour, and a sync thread parked on a lock for that long is a thread that cannot notice the app being switched off.

The consequence to know about is that a phone doing its first full import pushes nothing until that import pass ends. After that, import passes are short and the two loops interleave.

## What each platform can do

| | CLI | Desktop | Mobile |
|---|---|---|---|
| Sync on demand | Yes | Yes | Yes |
| Sync on a timer | With `--watch` | Yes | Yes |
| Sync while the app is not on screen | Not applicable | Not applicable | While automatic import is on: Android continuously, iOS when the system allows |
| Enable syncing and Wi-Fi-only settings | No, the command decides | Yes | Yes |
| Refuse over cellular | No connection type is reported | No connection type is reported | Yes |
| Consolidate an unrelated remote | Yes | Yes | No |

The sync engine itself is platform-neutral: `syncDatabases` in `packages/node-api/src/lib/sync.ts`, reached on every platform through the `sync-database` background task. What differs per platform is only what decides to run one.

## What the app shows while it is happening

The `sync-database` task sends `sync-started`, `sync-completed` and `sync-skipped` messages as it goes, and the app turns the first two into the spinner in the navbar. A sync that skipped early says why, in the app log, which is the only place that reason is visible.

A background sync sends the same messages into a WebView that may not exist. Nothing depends on them arriving: they drive a spinner and a log line, and the sync itself is finished by the task, not by anything that hears about it. That is also why the smoke tests read the origin rather than waiting for a message.

## Tests

Unit tests sit beside the code under `src/test/`.

| Test | What it covers |
|---|---|
| `packages/api/src/test/lib/sync-gate.test.ts` | The rule that decides an automatic sync is permitted: the two settings, offline, and each connection type. |
| `packages/node-api/src/test/lib/sync-database.worker.test.ts` | The `sync-database` task itself, which is what every platform queues. |
| `packages/node-api/src/test/lib/sync-early-out.test.ts` | A sync doing nothing, cheaply, when both sides already hold the same content. |
| `packages/node-api/src/test/lib/sync-metadata-edit.test.ts` | An edit reaching the origin. |
| `packages/mobile-worker/src/test/lib/plan-sync.worker.test.ts` | What the background loop is told to do: every way a sync is refused, and the way it runs. |
| `packages/mobile-worker/src/test/shims/network-status.test.ts` | The connection type crossing from native into that rule, and an unrecognised one becoming "unknown" rather than stopping syncing. |
| `packages/mobile-frontend/src/test/mobile-edit-sync.test.ts` | The sync an edit starts, and that it still asks whether syncing is permitted. |
| `apps/android-frontend/.../BackgroundPassLockTest.java` | The lock that keeps a sync pass and an import pass apart. |
| `apps/android-frontend/android/app/src/test/java/au/com/codecapers/photosphere/jsengine/SyncDriverTest.java` | The Android loop's decisions on the JVM, with no device: a plan saying stop ends it, a failed pass does not, and a second pass cannot start while one is in flight. |
| `apps/ios-frontend/ios/App/AppTests/` | The same decisions for the iOS driver, and the connection-type reporting. |

End to end:

| Test | What it proves |
|---|---|
| `84-watch-sync-evict` (CLI) | Imports reach the origin once `psi sync` pushes them, and the local originals stay. |
| `85-consolidate` (CLI) | Sync working after consolidation where it refused before. |
| `86-multi-device` (CLI) | Two databases connected to one remote each end up with the other's photos. |
| `bun run test:cli:sync` | Several processes syncing one database at once. |
| `24-sync-settings` (Electron) | Each toggle recomputes whether syncing is permitted and pushes that to the main process, and both values persist to `desktop.toml`. |
| `36-consolidate-database` (Electron) | Consolidating through the UI leaves ordinary sync working. |
| `45-s3-share-replica-sync` (mobile, Android) | An edit made on the phone reaching an encrypted S3 origin, and the early-out firing when there is nothing to sync. |
| `50-background-sync` (mobile, Android) | A photo imported while the app is backgrounded, and again while the screen is off, reaching an S3 origin without the app being opened. With **Enable syncing** switched off nothing reaches the origin while the app and its service are still running; switched back on, the same photo arrives. Everything is measured by reading the bucket, because a backgrounded WebView may have its socket to the harness suspended, which is the exact moment the test cares about. |

`50-background-sync` runs against a real phone as well as an emulator, and passes on both. On a phone it wipes nothing: it borrows the phone's settings files and keychain and hands them back, and syncs a database named for the test rather than the phone's own. Two things differ on a phone, and both are the route to the host rather than anything about syncing. Automatic import is pointed at an album of the test's own, because watching the whole library would import somebody's photo collection into a test database. And the last photo is a small one: a phone reaches the host through the port reverses adb sets up over USB, since the app permits cleartext only to localhost, and a two megabyte upload through that tunnel times out every time, measured with the screen on and with it off. The emulator keeps the large photo, because it reaches the host over a real network and carries it.

A phone showing its lock screen cannot run the test at all, and it says so rather than failing later: from Android 12 an app that is not in the foreground may not start a foreground service, and an app launched behind a lock screen is not in the foreground.

The **Only sync over Wi-Fi** restriction is not covered end to end. Driving it means changing the device's connection type to cellular, and reconfiguring a pool emulator's radios is forbidden: the emulators are shared with every other test run on the machine. The rule itself is covered by unit tests on both sides of the bridge, including the cellular case, which is where the decision is actually made.

The mobile tests are Android only. `apps/smoke-tests/tests/50-background-sync/IOS-NOT-COVERED.md` says what iOS cannot cover and why: a `BGProcessingTask` is scheduled by the system, and the only way to force one is an lldb command against a running app, which this harness cannot issue on Xcode 14.2.

## See also

- [Automatic photo backup](automatic-photo-backup.md) - what puts the photos in the database in the first place, and the loop this one is modelled on.
- [Mobile background tasks](mobile-background-tasks.md) - the engine pool both background loops run on.
- [Background tasks](background-tasks.md) - adding a new task type and wiring it up on every platform.
