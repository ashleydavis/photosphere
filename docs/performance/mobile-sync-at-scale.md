# Prefetch, syncing and importing on a phone, against a real library

## What was measured

What a phone actually does when it holds a partial replica of a database with thousands of photos in it: how long the first open takes, what the prefetch fetches and how long for, what a sync pass moves and how often one runs, whether syncing and the prefetch fetch the same files, and what automatic import does at that size.

## The short version

- **86 seconds before the first photo appears**, and **ten and a half minutes** before the last of 8,109 records is loaded. Reopening the same database saves about a fifth of that.
- **The prefetch does not finish.** It pulls all 8,185 missing thumbnails down in twenty minutes and then dies on the database index files, after 38 minutes, and nothing ever re-queues it.
- **A sync pass with nothing to do costs 154 milliseconds** and the five minute gap between passes is honoured exactly. The "passes ten seconds apart" behaviour did not reproduce.
- **A sync can never fill in a partial replica.** Not because of the partial-target filter, but because it decides what to copy from a merkle tree difference, and a partial replica's tree is already identical to the origin's. A missing file is invisible to it.
- **Syncing and the prefetch do not contend for engine slots** (the pool has five and they use two between them) and **do contend hard for the network**.
- **A batch of 250 photos takes sixteen minutes to write** into a database of 8,231, and the import does nothing else for the whole of it.
- **A phone cannot push an original to an S3 origin at all.** Every attempt fails inside the AWS SDK's multipart upload with `not a function`, the sync catches it and carries on, and nothing tells the user. After 2 hours 18 minutes of importing, 441 photos were on the device and **not one byte had reached the origin**.

Five bugs turned up on the way to taking these measurements. Two of them are the same mistake, a `retry` left on its thirty second default around work that legitimately takes longer, and `sync.ts` already carries a comment about having been bitten by it in a third place. Only the ones that blocked the measuring were fixed; the rest are recorded here as the evidence a later change would be written against.

## What it was measured against

The real database was copied once, in full, into a local MinIO server, and the phone was pointed at the copy. The real bucket was read exactly once, to make that copy, and nothing here ever wrote to it or connected the phone to it.

- **Device**: Pixel 6 (`oriole`), Android 16, attached over USB and on the same Wi-Fi network as the host.
- **Origin**: MinIO `RELEASE.2025-09-07T16-13-09Z`, single node, started by `scripts/s3-emulator.sh`, serving the bucket `<test-bucket>` on the host's LAN address. The phone reached it over Wi-Fi, not through an `adb reverse`: a reverse carries every byte over USB, which is far faster than the connection a phone would really use and would make every number here meaningless.
- **Database**: a full copy of a real photo library, encrypted with the same key as the original.
- **Date**: 9 and 10 September 2026, in one session.

### How the copy was made

```
psi replicate --db s3:<real-bucket> --dest s3:<test-bucket> --full --yes --dest-key <encryption-key>
```

with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_ENDPOINT` on the command line pointing at MinIO. The source and the destination get their credentials from different places in that one command, which is what makes it possible: `resolveStorageCredentials` prefers a `databases.toml` entry's vault key and falls back to the `AWS_*` variables, and only the source has an entry.

**MinIO does not serve a directory of files as a bucket.** It stores every object as a directory containing `xl.meta`, so files written into its data directory are not objects and replicating into that directory produces nothing readable. The copy has to go through the S3 API.

### How the phone was set up

Its own settings and keychain were saved first, the way `50-background-sync` does, so a real phone is never wiped. It turned out to have none: no `config.yaml`, no `databases.toml` and no secure store, so there was nothing to borrow and nothing to hand back.

Two secrets went on:

- The MinIO S3 credentials, through the app's own Add Secret dialog.
- The database's encryption key, with `psi secrets send --name <key> --code <code>` from the host into the app's Receive Secret dialog. It cannot go on any other way: the Android secure store is `EncryptedSharedPreferences` over an Android Keystore master key, so its contents cannot be authored on the host, and the Add Secret dialog has no field for a pasted PEM.

## How it was instrumented

Temporary logging under one prefix, `PSMEASURE`, so `adb logcat` could be filtered to it. It was removed once the numbers were taken, so what follows describes what it did rather than pointing at code that is still there.

| Where | What it said |
|---|---|
| `prefetch-database.worker.ts` | Start, the walk of each origin directory with how many files were there and how many were missing, each batch with its duration, each file by name, and the end with the totals. |
| `sync.ts` | Start, what the early-out decided, each push direction separately with files copied, bytes, files left behind, and files skipped by the partial filter, as deleted, and as already present. Each copied file by name. |
| `sync-database.worker.ts` | Start, the origin it resolved, and the end with whether anything synced and how many changes. |
| `load-assets.worker.ts` | Start, each page with its record count and duration, the time to the first page, and the end with the totals. |
| `plan-sync.worker.ts` | Every decision, with the reason, the pause and the settings it was made from. |
| `SyncDriver.java`, `AutoImportDriver.java` | Each pass start and end with its outcome, the plan it read, each step, and around each pause: the gap asked for, the gap actually waited, and whether anything cut it short. |
| `AutoImportService.java` | The service starting, and every notify of the lock the two loops wait on. |
| `QuickJsTaskEngine.java` | Each task dispatched to an engine and each one settling, with the engine's identity, so the five engines' occupancy can be read off. |

The engine occupancy is logged from `QuickJsTaskEngine` rather than `EnginePool` because the pool has JVM unit tests and `android.util.Log` throws "not mocked" under them.

## A bug this found before it could measure anything

`psi replicate` could not copy any file that takes longer than thirty seconds to move, so the first attempt at the copy died 165 MB in with `Operation timed out after 30000ms: () => copyAsset(...)`.

`processMerkleNode` wrapped `copyAsset` in `retry(...)` with no timeout argument, so the default thirty seconds applied around the whole of it. The copy inside `copyAsset` already asks for `LARGE_FILE_TIMEOUT`, and that allowance can never be reached while a thirty second timer is running outside it. `sync.ts` passes the long timeout at exactly the same point in its own copy loop, having been bitten by the same thing on a phone.

Fixed by passing `LARGE_FILE_TIMEOUT` to that outer retry, and to the periodic merkle tree save beside it. Covered by `copies a file that takes longer than the default retry timeout to read` in `packages/node-api/src/test/lib/replicate.test.ts`.

The effect on the product was that a full replication of any database holding a large file failed outright, three retries in, wherever the connection was slow enough. On this connection that was anything over about fifteen megabytes.

## And a second one, which is the same mistake at a different scale

With the file copies allowed to take as long as they take, the copy then died at exactly forty minutes, two thirds of the way through, with `Task <id> timed out after 2400000ms`.

The worker pool gives every dispatched task a deadline, and it measured that deadline from the moment the task was dispatched. So the deadline ended a task that was simply long, which is what a whole-database replication of a real library is: it had reported progress on every one of the thousands of files it had copied, and was killed anyway. `replicate` does not take the `--timeout` flag that `verify` and `check` take, so there was no way for a user to raise it either.

A deadline on a worker exists to notice a worker that has stopped answering. Measured from dispatch it cannot tell that apart from work that is taking a while, which is exactly the distinction it needs to make. It now measures silence instead: every message a worker sends restarts its task's deadline, so a task that is talking is never given up on, and one that has gone quiet for the whole limit still is.

The bookkeeping for that is now `TaskDeadlines` in `packages/task-queue`, used by both worker pools, which previously held a timeout map and four `clearTimeout` call sites each. `packages/task-queue/src/test/lib/task-deadlines.test.ts` covers it, including a task that runs for twenty times the limit while reporting progress and is not given up on, and the same task going quiet afterwards and being given up on.

The same limit applies to `sync-database`, so the first sync of a large library from the desktop or the CLI was on course to be killed at forty minutes in the same way.

## And a third, which is why the copy could not be read back

`psi summary` against the path the replication had just finished writing reported **"No database found at: s3:<test-bucket>"**.

`loadDatabase` resolves S3 credentials for a path the database list says nothing about with `getDefaultS3Config`, which read the vault's `default:s3` secret and nothing else. Every worker resolves the same path with `resolveStorageCredentials`, which reads a vault secret only when the path's entry names one and otherwise uses the `AWS_*` environment variables, never consulting `default:s3`. So the CLI's pre-flight and the worker doing the work looked in two different accounts for one path: the replication wrote a whole database into the bucket the environment named, and the summary then said there was no database there, having looked in the account the vault names.

`getDefaultS3Config` now reads the environment first and falls back to `default:s3`, which is the order every worker already uses. Four tests in `apps/cli/src/test/lib/init-cmd.test.ts` cover it, including the precedence.

## The copy, and what it holds

```
Mode:             full
Files imported:   8231
Total files:      24260
Total size:       33.9 GiB
Database version: 6
Files hash:       91539536f5c953d70aa43577c535aab0afbc93d2be65f2a3f58f4068fb82943e
Database hash:    efcb3f17e69336d2123ba8d6ac80a9ac9670a0cee388b5ef6b4b3c02df87125a
Full root hash:   c4d2a92dbc57801c7e98a6ea1bc451bf31b39fdd4406b3ff040dc41541dad646
```

`psi verify` against the copy read all 24,260 files and reported 24,260 unmodified, 0 modified, 0 failures, 0 record mismatches, and 220 database files of 353 MiB all valid.

The phone's replica is a partial one taken from that copy with `psi replicate --partial`, which is 3.7 MB and 109 files. **A partial replica is not merkle trees alone**: 104 of those 109 files are under `.db/bson`. What it does not have is the thumbnails, and most of the database index.

## Opening the replica for the first time

Syncing off, automatic import off, app launched cold, replica opened from the Open Database dialog.

| | |
|---|---|
| Time to the first photo on screen | **86.3 seconds** |
| Time to the last | **10 minutes 25 seconds** |
| Pages | 8, of about 1,000 records each |
| Time per page | 58 to 84 seconds, with no downward trend |
| Records loaded | 8,109 |

Of the 86.3 seconds before anything appears, 70.7 is the first `getPage` and the remaining 15.6 is opening the storage and the database before a page is even asked for.

The count climbs in eight jumps of about a thousand, roughly eighty seconds apart, which is exactly what a user sees: a number that sits still for well over a minute and then leaps.

**8,109 records against the origin's 8,231 photos.** 122 short. Nothing here establishes whether those are deleted assets the sort index leaves out or something missing, and it is recorded rather than explained.

**Reopening the same database is not much faster.** The second open of the same replica reached its first page in 62.5 seconds and averaged about 50 seconds a page, against 86.3 and about 78. The lazily fetched sort index pages are cached locally by `LazyOriginStorage`, so some of the work is saved, but four fifths of the wait is still there.

## The prefetch

`load-assets` queues the prefetch at the end of its own run, so on a first open the phone spends ten minutes reading records and only then starts fetching the thumbnails those records need. The two never overlap.

| | |
|---|---|
| Thumbnails at the origin | 8,231 |
| Missing locally | 8,185 (the partial replica arrived with 46) |
| Time to fetch them | **19 minutes 54 seconds** |
| Rate | 6.8 files a second, three at a time |

Nothing about that rate changes over the twenty minutes. `PREFETCH_CONCURRENCY` is 3 and each batch takes 300 to 500 ms, so it is bound by round trips rather than by bandwidth.

### Then it fails

After the thumbnails it moves on to `.db/bson`, and there it dies:

```
22:31:23.635 PSMEASURE prefetch batch n=2763 files=3 batchMs=534318 totalFiles=8289
22:31:24.035 E JsEngineQuickJs: Task ... failed: Operation timed out after 30000ms:
             async () => { const stream2 = await originStorage.readStream(filePath);
             await localStorage2.writeStream(filePath, undefined, stream2); }
```

The task ran for **38 minutes 27 seconds** and threw. It had fetched 8,289 files: every missing thumbnail, and 104 of the database files. It never reached the rest of the index.

**This is the same bug as the first one, in a third place.** `prefetchDatabaseHandler` copies each file inside `retry(async () => { ... })` with no timeout argument, so the default thirty seconds applies. The metadata hash index at this scale is nine files totalling 118 MB, about 13 MB each, and the phone cannot pull one down and write it inside thirty seconds. Each times out, is retried, times out again, and crawls through on a later attempt at one file every four and a half minutes against the twenty-five seconds it should take, until one of them exhausts its three attempts and takes the whole prefetch with it.

Thumbnails are unaffected because a thumbnail is small. It is only the database files, which are exactly what a phone needs before it can do anything, that are big enough to hit it.

**Nothing re-queues a failed prefetch.** `load-assets` is the only thing that queues one, so the replica stays permanently short until the database is opened again.

So: a prefetch of eight thousand thumbnails takes twenty minutes, and a prefetch of this database does not finish at all.

## Syncing

| | |
|---|---|
| A pass with nothing to do | **154 ms** |
| Reading the plan | 21 ms |
| Reaching the origin's merkle tree over S3 | 97 ms |
| The early-out on the two content hashes | 24 ms |
| Gap between passes | exactly 300,000 ms, the configured value |

Five passes were captured. Every one decided `identical-content-hash` and moved nothing, in 83 to 154 ms.

`docs/syncing.md` describes the cheap case as "two small file reads, one of them at the origin". That is exactly what it is, and 154 ms is what it costs on this phone against an S3 origin.

### The gap is not cut short

Every pause logged `askedMs=300000 waitedMs=300000 cutShortBy=nothing`. The "passes ten seconds apart against a five minute setting" that motivated instrumenting this **did not reproduce**, in any pass captured over the whole session. `AutoImportService`'s two `pause` implementations still call `Object.wait(millis)` once rather than looping to the deadline, so a spurious wakeup would still cut a gap short, but nothing observed here did.

### A sync does not fill in a partial replica, and the reason is not the partial filter

`copyFile` in `sync.ts` does copy thumbnails and root files into a partial target. But that code is never reached, because the early-out fires first: a partial replica made by `psi replicate` has the same content hash as its origin, since the content hash is of the merkle tree and the replica has the whole tree. Missing files do not change it.

The consequence matters more than the mechanism: **a partial replica whose prefetch failed is never repaired by syncing.** Both sides go on saying they are identical for ever while the phone is missing the database index it needs.

## Syncing and the prefetch together

A second fresh partial replica, opened while syncing was already on.

Sync passes landed at 22:51:06, 22:56:06 and 23:01:06, in the middle of first the load and then the prefetch. Each took 83 to 146 ms and early-outed. The engine log shows why nothing queues:

```
22:51:06.020 engine dispatch engine=230997153 type=plan-sync     source=background-sync
22:51:06.043 engine settled  engine=230997153 type=plan-sync     outcome=succeeded
22:51:06.046 engine dispatch engine=30173134  type=sync-database source=background-sync
22:51:06.129 engine settled  engine=30173134  type=sync-database outcome=succeeded
```

Two engines, neither the one holding `load-assets`, both given back within a tenth of a second. `EnginePool.POOL_SIZE` is **5**, a prefetch holds one, and a sync pass borrows two for a moment every five minutes, so the pool is never close to full.

The prefetch's rate is unchanged by a sync running beside it: 6.3 files a second against 6.8 alone. The load is about 17% slower with the loop running (12 min 10 s against 10 min 25 s), and effectively none of that is the sync itself, which totals under half a second across the whole run.

**They do not fetch the same files at the same time, and they do not contend. They cannot, because the sync does nothing at all.**

Opening a second database while the first is still loading cancels the first load rather than running both: `load-assets end ... cancelled=true` at page 7.

## Importing a whole photo library, beside all of it

Automatic import switched on with `default_database_path` pointing at the partial replica, so it imports into the replica rather than making a database of its own. Syncing already on. Within seconds of the app restarting, three things were running at once: `load-assets` reopening the replica, a sync pass, and `import-assets`.

**The service will not notice a settings change made from outside the app.** `AutoImportService.onStartCommand` starts the import loop only when that loop's thread is dead, and `am start-foreground-service` from a shell is refused. The app has to be restarted, which is what switching the toggle on does anyway.

### The scan

`Automatic import found 50 item(s) in the source, 50 of them new`, 46 times, then a page of 8.

- **2,308 items, every one new**, because the hash cache for this database is empty.
- **51 seconds to list the whole library.**

### The photos

**251 photos in 47 minutes, about 5.3 a minute**, falling as it goes. Where it stalls it is behind a single long `upload-asset`, with the prefetch pulling from the same origin over the same Wi-Fi. The two do not contend for engine slots and do contend hard for the network.

### The batch write takes sixteen minutes and stops everything

```
23:53   write.lock taken
00:02   .db/files.dat rewritten, 2,520,796 -> 2,591,020 bytes
00:09   .db/bson committed, .db/state.dat stamped
```

Not one `upload-asset` was dispatched or settled between 23:53:53 and 00:09. Saving the merkle tree alone is nine of those sixteen minutes.

That is one batch of 250 photos going into a database that already holds 8,231.

### For 68 minutes the origin received nothing

Every sync pass before the batch write early-outed, because nothing had been committed to the local database so its content hash had not changed. The bucket sat at 24,484 objects. What the phone had done in that hour was take in, hash, generate derivatives for and store 251 photos that appeared in no gallery and existed on no other machine.

### The sync that finally had something to do

```
00:12:16.930 sync-task start
00:13:38.462 sync-task origin connectMs=81532
00:13:38.526 sync early-out decision=proceed
00:13:38.528 push start direction=pull-origin-to-local
00:15:37.778 push end   direction=pull-origin-to-local filesCopied=0 leavesVisited=0 nodesVisited=0 elapsedMs=119250
00:15:56.269 Finding differing records using hierarchical merkle trees...
00:31:01.279 No differing records found.
00:31:25.177 push start direction=push-local-to-origin
```

- Reaching the origin took **81.5 seconds** under load, against 97 ms idle.
- The pull copied nothing and **visited no nodes at all**.
- The record merge took **15 minutes**.

`nodesVisited=0` is the better answer to why a sync cannot fill in a partial replica, and it replaces the early-out explanation. `pushFiles` decides what to copy from `findMerkleTreeDifferences(source.merkle, target.merkle)`. A partial replica has the **whole** merkle tree; what it lacks is files the tree already describes. The difference is empty, no leaf is ever considered, and `copyFile`'s partial-target branch is never reached with anything to skip (`skippedPartialFilter=0`).

**A sync cannot see a missing file. It can only see a tree that differs.**

### The fifth bug: a phone cannot push an original to S3 at all

```
Failed to copy asset/1adf5a81-3acc-424f-8cc0-f9851d59d178, carrying on with the rest of the sync
Failed to copy file asset/1adf5a81-...: Failed to write stream to
  <test-bucket>/asset/1adf5a81-...: not a function: not a function
    at getDataReadable (worker.bundle.js:88348)
    at getChunkStream (worker.bundle.js:88316)
    at __doConcurrentUpload (worker.bundle.js:88618)
    at __doMultipartUpload (worker.bundle.js:88624)
    at done (worker.bundle.js:88453)
    at writeStream ... at writeStreamHashed ... at copyFile
```

The AWS SDK's multipart upload path calls something the embedded engine does not have. Every original the push attempted failed this way and **none succeeded**. No thumbnail or display copy was ever reached, because the tree walk hits originals first.

`syncDatabases` catches a failed file copy deliberately, so one bad file does not end a pass, and leaves it for the next pass. With this failure that means every pass tries every original and fails on every one, for ever, and nothing tells the user: the interface shows a sync that ran and completed.

**This is what stops background import and syncing working at this scale.** The phone takes photos in perfectly well and then cannot push a single original off the device.

### Memory

```
An operation failed. Retrying after: Failed to allocate a 83186008 byte allocation with
69322160 free bytes and 66MB until OOM, target footprint 268435456, growth limit 268435456
```

An 83 MB allocation refused during the sync. Something in that path holds a whole file, shard or index in memory at this scale.

### Where it stood after 2 hours 18 minutes

| | |
|---|---|
| Library items scanned | 2,308, all new |
| Photos taken into the local database's storage | **441** of 2,308 |
| Batches committed | **1**, of 250 |
| Files pushed to the origin | **0** |
| Originals the push tried and failed | 123, every one with `not a function` |
| Origin objects, start to end | 24,484 to 24,485, the extra one being the sync's write lock |
| Origin size, start to end | 35 GB, unchanged |
| Replica on the device, start to end | 186 MB to 1,438 MB |

**The phone did 1.25 GB of work and the origin received none of it.**

441 photos in 138 minutes is 3.2 a minute, so the whole library would take about **12 hours**, plus a sixteen-minute batch write every 250 photos, and every one of those gets slower as the database grows.

The run was stopped there rather than left to finish. What it would do for the remaining 1,867 photos is what it did for the first 441, and the push failure means waiting does not change the answer.

## What was not measured

- **Deduplication against a database that already holds the phone's photos.** This is the case worth knowing about, and it could not be reached: the copied database and this phone's library turned out to have almost nothing in common, so all 2,308 items were new and every one the import processed was taken in rather than skipped. Nothing here says what happens when the database already holds them.
- **The import to completion.** Stopped at 441 of 2,308.
- **The prefetch to completion in the both-running case.** Step 6 already established what happens when it reaches the database files, and the time was spent on the import instead.
- **A second batch write.** Only one commit happened, so nothing here shows how the sixteen minutes grows as the database does.
- **iOS.** Everything here is Android.
- **A sync that actually moves a file.** Every attempt failed, so there is no measured cost for a successful push from a phone.

## What is left behind

On this machine:

- The MinIO server, still running, and its data directory holding the 35 GB copy of the database, under the worktree's `tmp/minio-state`. Stop it with `bash scripts/s3-emulator.sh stop tmp/minio-state`; removing the data directory is what reclaims the 35 GB.
- The two partial replicas the phone's copies were made from, `tmp/measure-replica` and `tmp/measure-replica-2`, and the raw captures under `tmp/measurements`.
- Nothing in `~/.config/photosphere` and nothing in the OS keychain was created, changed or removed.

On the phone:

- Two test databases in the app's sandbox, `files/measure-replica` and `files/measure-replica-2`, the second holding 441 imported photos.
- `files/databases.toml` naming those two and the test bucket, and `files/config.yaml` with both features switched off.
- Two secrets in the app's keychain: `minio-measure` and `<encryption-key>`.
- The device had none of those files before this work, so there was nothing of its own to put back.
- The instrumented build is still installed. Reinstalling from a clean build replaces it.

## What has been fixed since, and what still stands

The measurements above are what they were on the day. Four of the five faults they turned up have been fixed; everything else here is still true of the app.

Fixed:

- **A phone could not push an original to an encrypted S3 origin at all.** The mobile stream shim's `Transform` had no `Symbol.asyncIterator`, and on an encrypted database every upload goes through the AWS SDK's multipart uploader, which async-iterates the body. It has one now, and `56-large-asset-push` reads the object back out of the bucket to prove a photo imported on a device arrives byte for byte.
- **The prefetch died on the database index files.** Each file was copied under `retry`'s thirty second default, which nine files of about 13 MB each cannot meet on a phone. They get `LARGE_FILE_TIMEOUT` now, as the same copy loops in `sync.ts` and `replicate.ts` already did.
- **A failed prefetch was never tried again.** It ran only when a database was opened. There is a background prefetch loop now, beside the import and sync loops, which retries until the replica is complete and then stops; `57-prefetch-retries` proves it fills a replica in with nothing having opened the database.
- **A sync and a prefetch fetching the same files at once.** A periodic sync now waits while a prefetch of the same database is making progress, and stops waiting if that prefetch stalls, so a prefetch that cannot finish cannot stop a phone syncing. `58-sync-waits-for-prefetch` proves both halves.

Still true, and not addressed:

- **86 seconds before the first photo appears**, and ten and a half minutes before the last of 8,109 records is loaded.
- **A batch of 250 photos takes sixteen minutes to write** into a database of 8,231, and the import does nothing else for the whole of it.
- **The 83 MB allocation that was refused during a sync**, and the memory pressure behind it.
- **The push order reaches originals before thumbnails**, so a replica gains its originals before it can show what they are.
- Everything under "What was not measured" above is still unmeasured.
