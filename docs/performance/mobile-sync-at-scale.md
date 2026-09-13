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

That was the first run. Four runs later the same three questions have different answers, and the sections at the end of this document say how each came about:

- **The prefetch finishes.** 8,491 files in 59 minutes 21 seconds, re-verified in 31 seconds on a restart.
- **The import finishes.** Every one of the 2,308 items in the phone's library is in the replica except the one that is not a photo or a video, at 7 to 9 seconds a photo once the read-back was gone, six hours a day being all the platform allows the service that does it.
- **The sync carries the library.** A pass that had every original and display version to push moved 3,068 files and 6.4GB in 40 minutes 37 seconds, merged 500 records in under six, and the pass after it left the origin holding everything the phone does.

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
- **The push order reaches originals before thumbnails**, so a replica gains its originals before it can show what they are.

The rest of what this section used to list as unaddressed has since been measured again and is covered below, which is where the current figures are.

## The second run, with the fixes in

Everything above is the first session, in September 2026. The same three things were measured again against the same 35 GB copy of the same database, on the same Pixel 6, with the four fixes above in place. What follows replaces the first run's figures wherever the two disagree.

The phone held a fresh partial replica of the copy, both secrets in its keychain, syncing on and nothing opening the database, which is the case the background prefetch loop exists for. Its library was 2,188 images and 120 videos, as before.

### Three faults had to be fixed before a number could be taken

- **The CLI could not read the copy back**, so no partial replica could be made: `getDefaultS3Config` read the vault's `default:s3` secret and nothing else, while every worker resolves a path the database list says nothing about from the `AWS_*` variables. The CLI's pre-flight and the worker doing the work were looking in two different accounts for one path. It reads the environment first now, which is the order the workers already use.
- **The background prefetch could not read an encrypted replica, so on a real phone it never ran once.** `plan-prefetch` asked `isDatabasePartial` whether the replica was partial without passing any credentials, so the merkle tree it reads to answer that was read as the raw ciphertext it is on disk and every pass threw "Checksum mismatch". A phone's database is encrypted, so that was the loop not working at all in the only case that matters, behind a green test suite: `57-prefetch-retries` only ever used an unencrypted replica. `59-prefetch-encrypted-replica` is the test that closes it.
- **A failed decryption was handed back as though the data had never been encrypted**, which is what sent the search for the fault above to the wrong place. `decryptBuffer` and `createDecryptionStream` both fell back to returning the bytes unchanged, so a missing or wrong key surfaced as a checksum mismatch reported from serialization. Both now throw when the data carries the `PSEN` tag. The genuine case the fallback exists for, a file that was never encrypted read through an encrypted storage, still works.

### The prefetch now finishes

| | First run | Second run |
|---|---|---|
| Thumbnails | 8,185 in 19 min 54 s | **8,231 in 20 min 33 s** |
| Database index files | **never fetched** | **116, about 352 MB** |
| Whole replica | **never completed** | **complete in 56 min 24 s** |
| File copies that retried or timed out | every index file, until one exhausted its attempts | **none** |
| Passes needed | one, which died | three |

The thumbnails cost the same both times, at a flat 6.7 files a second three at a time, because nothing about them was ever broken. What changed is everything after them: the index files come down at about 200 KB/s and the `LARGE_FILE_TIMEOUT` around each copy means a 14 MB file simply takes its eighty seconds instead of timing out at thirty and eventually ending the prefetch.

**A fourth copy of the same timeout mistake turned up here.** `walkDirectory` wrapped both of its listings in `retry` with no timeout, so a pass died 35 minutes in on `storage.listDirs`. The listing was not slow: all three attempts expired inside the same 80 milliseconds, and the engine reported 193 seconds of task time with 81 milliseconds of pumping, because the engine thread sits inside synchronous host calls while it moves bytes and a wall-clock timeout then measures time the work was never given. The bound is now `DIRECTORY_LISTING_TIMEOUT`.

**The loop recovered from it**, which is the thing it was built for: each pass skips what is already on the phone, so the second walked past all 8,231 thumbnails and fetched nine more index files, and the third finished the last one. Without the listing fault the same work is one pass of about 37 minutes.

A confirming pass over a complete replica costs **24 to 36 seconds**: the whole walk of both directories plus a local existence check for every file, with nothing to fetch. That is the number behind the loop stopping rather than asking again every gap.

**The sync's deferral fired exactly once, after the work was finished.** It reads what the last *completed* pass found, and a pass over a real library is longer than the interval it is meant to protect, so every sync during the 35 minutes that mattered ran with the state still unknown. It cost nothing (those passes were 19 to 37 ms each) and the mechanism is right, but at this scale it is worth close to nothing.

### The import is four times faster, and starts ten times slower

| | First run | Second run |
|---|---|---|
| Library scan | 2,308 items in 51 s | 2,308 items in 83 s |
| Time to the first thing found | about 40 s | **6 min 17 s** |
| Photos stored per minute | 5.3 | **21, falling to under 2** |
| One batch of 250 committed | 16 minutes | **44 minutes 39 seconds** |

The import is faster because the prefetch had already finished and stopped, so nothing else was using the connection: filling the replica in costs an hour and then pays for itself.

Its start and its commits are far slower, and for the same reason in reverse: the replica now holds the whole 595 MB database index locally, so the import reads, decrypts and rewrites the real thing. Six minutes of that is solid CPU on one core with nothing logged, and 17.3 of the commit's 44.6 minutes is the merkle tree save alone. Nine batches for the whole library is about six and a half hours of committing on top of the importing.

Every one of the 2,308 items was new again, so **deduplication against a database that already holds the phone's photos is still unmeasured**.

### A video of 87 MB could not be imported at all

```
Error importing file .media-tmp/1000008065.mp4
Failed to allocate a 90894120 byte allocation with 51397312 free bytes and 49MB until OOM,
target footprint 268435456, growth limit 268435456
    at callHost (worker.bundle.js:13439)
Run loop for upload-asset: 1 iterations, 347560ms pumping, 0ms waiting for events
```

The file is 90,893,534 bytes and the refused allocation is 90,894,120: the whole file in one buffer, inside a host call, on a Java heap whose growth limit is 256 MB. It cost 5 minutes 47 seconds of solid execution across three attempts and the video was never imported.

**This is the 83 MB allocation the first run recorded and could not explain.** `createReadStream` had already been made to walk a file 4 MB at a time after a 100 MB video killed a sync; `createWriteStream` still buffered every chunk and handed the whole file over in one call on end, so the host had to hold an allocation of the file's own size. It flushes in the same 4 MB chunks now, through a new `fsAppendFile` host function on both platforms.

### The sync does not finish. It kills the app.

The first pass with something to push started 37 seconds after the commit released the write lock.

```
21:11:58.678 Sync started for "measure-replica-4" (origin: s3:...)
21:13:46.490 Push completed: 0 files copied, 0 left behind for the next pass, 0 deleted from target
21:14:08.911 Finding differing records using hierarchical merkle trees...
21:24:19.712 An operation failed. Retrying after: Failed to allocate a 83186008 byte allocation
             with 68891328 free bytes and 65MB until OOM, target footprint 268435456
21:27:07.816 Task b49595cf failed: null  (com.whl.quickjs.wrapper.QuickJSException: null)
21:27:08.211 libc++abi: terminating due to uncaught exception of type St9bad_alloc: std::bad_alloc
```

`std::bad_alloc` on three threads at once is the process aborting for want of native memory. Nothing restarted it, foreground service or not: the app was still gone 75 minutes later.

| | |
|---|---|
| Pull, origin to local | 108 seconds, 0 files copied |
| Record merge before the crash | 13 minutes, almost all of it blocked in host calls |
| Native heap, read a few minutes earlier | **3.6 GB** |
| Files pushed to the origin | **0** |
| Origin objects and bytes, start to end | 24,485 and 36,818,048,661, **unchanged** |

The 83,186,008 byte figure is the first run's, exactly. That run saw the allocation refused during a sync and survived it; this one did not.

**It happened twice, in two different tasks, and the second time the tombstone named the cause.** The app was restarted with the two fixes below in place and given the import again; seventeen minutes later, during the import's own database work rather than a sync, it aborted the same way. Android's dropbox has the backtrace:

```
signal 6 (SIGABRT), code -1 (SI_QUEUE)
  #00 abort+156                                  libc.so
  #01 scudo::die()+8                             libc.so
  #02 scudo::reportRawError(char const*)+28      libc.so
  #03 scudo::reportMapError(unsigned long)+172    libc.so
  #04 scudo::MemMapLinux::remapImpl(...)         libc.so
  #05 scudo::MapAllocator<...>::allocate(...)    libc.so
  #07 scudo_malloc+36                            libc.so
  #08 malloc+44                                  libc.so
  #09 <offset 0x2e48000>                          libquickjs-android-wrapper.so
```

`malloc` failed inside the QuickJS wrapper, the allocator could not map more memory, and it aborted the process. So this is not one oversized buffer: **the embedded engine's native memory grows until the process cannot allocate at all**, and both the sync's record merge and the import's database work at this scale get there.

**It is probably the accumulation `QuickJsTaskEngine` already works around, in the one place the workaround cannot reach.** That class throws its QuickJS context away and builds a new one every hundred tasks, and the comment on it says why: an import of a real library ran about three hundred photos in and then failed every one after that with a stack overflow raised one frame deep, which restarting the app cleared every time, and what accumulates was never found. The rebuild happens when a task is dispatched. `import-assets` and `sync-database` are each a *single* task that runs for minutes or hours, so no rebuild can happen while one is running and whatever fills the context up is unbounded inside it. That is the first thing to look at, and it means the existing workaround should not be read as covering this.

**The engine asks QuickJS for no memory policy at all.** The wrapper it uses (`wang.harlon.quickjs:wrapper-android:3.2.0`) exposes `setMemoryLimit`, `setGCThreshold`, `runGC`, `getMemoryUsedSize` and `dumpMemoryUsage`, and `QuickJsTaskEngine` calls none of them. With no memory limit QuickJS never refuses an allocation: it asks the system for more until `malloc` fails, and a failed `malloc` in that library aborts the process rather than raising a JavaScript error, which is why the app disappears instead of reporting a failed sync.

**Setting a GC threshold was tried and is not the fix.** `setGCThreshold(16 MB)` at context creation was measured against the same sync, twice, and the result narrows the search rather than solving it:

| | Default schedule | 16 MB threshold |
|---|---|---|
| How long the record merge survived | 12 min 59 s | **18 min 3 s** |
| Abort message | `Scudo ERROR: internal map failure (error desc=Out of memory)` | the same |
| Thread | an engine thread | an engine thread |

So collection is not what is short. Bounding it buys about forty per cent more time and the process still cannot map memory, which means **what accumulates is not mostly collectable JavaScript garbage**. The change was reverted rather than kept, because delaying a crash is not fixing one. What is left to try, in order: give QuickJS a memory limit so the failure is a JavaScript error a task can report rather than an abort, and use `getMemoryUsedSize` and `dumpMemoryUsage` during a merge to find what the engine is actually holding.

A third crash in the same session was different and is worth separating out: with the app left foregrounded for hours the WebView's renderer aborted on `VK_ERROR_DEVICE_LOST (RenderThread context): GPU fault`, not an engine thread. Backgrounding the app, which is what background sync is for, removed that one and left the memory abort as the only failure.

**So the origin still receives nothing from a real library on a real phone, for a second and independent reason.** The `not a function` failure that stopped every upload in the first run is genuinely fixed, and `56-large-asset-push` proves a photo imported on a device arrives in the bucket byte for byte. What stops it at this scale now is memory, and it is the largest open fault the two runs have found.

### What was fixed during this run

- **`walkDirectory`'s listings had `retry`'s thirty second default**, so a prefetch pass died 35 minutes in on a directory listing. `DIRECTORY_LISTING_TIMEOUT`.
- **The background prefetch could not read an encrypted replica**, so it never ran on a real phone. Covered by `59-prefetch-encrypted-replica` and by unit tests against a genuinely encrypted replica.
- **A failed decryption was handed back as plaintext**, by both the buffer and the stream path. Both throw now when the data carries the encryption tag, and a key too small for the format is refused at the write rather than producing files nothing can read.
- **`createWriteStream` handed whole files to the host in one call**, which is why an 87 MB video could not be imported. It flushes in 4 MB chunks through `fsAppendFile`.
- **`psi` could not read a bucket the `AWS_*` variables name** when the database list said nothing about it.
- **A media file that no tool can read reported "ffprobe exit code 1: {}"**, which reads like the app is broken. The message names the file and its size now. One file in this library is a 794-byte Messenger download named `.mp4`, and skipping it is correct; what was wrong was only the report.

### Still open, in order of what it costs

- **The engine exhausts native memory and the process aborts**, in both the sync's record merge and the import's database work, against a database of this size, three times in one session. This is what stops a phone backing up a real library. A GC threshold was tried and only delays it, so the next things to do are a memory limit, so the failure is something a task can report rather than an abort, and `dumpMemoryUsage` during a merge to find what is held.
- **The import needs six minutes of solid CPU to open a complete replica** before it finds anything.
- **A batch of 250 photos costs 44 minutes to commit** into a database of 8,231, 17 minutes of which is saving the merkle tree.
- **A media item that can never be read is retried on every pass for ever.** Cheap for a 794-byte stub, 5 minutes 47 seconds an attempt for the 87 MB video before it was fixed. The import has no notion of an item that is permanently unreadable.
- **The prefetch deferral is worth almost nothing at this scale**, because it reads the last completed pass and a pass over a real library outlasts the interval it protects.
- Everything under "What was not measured" above, and deduplication in particular, is still unmeasured: the copied database and this phone's library have almost nothing in common, so every item is new both times.

## The third run: the sync finishes

The same Pixel 6 and the same library of 2,308 items, against a replica of a copy of the database served by MinIO on the same LAN. The copy holds every thumbnail but only the originals and display versions the phone had already pushed, because it was rebuilt from the phone's own partial replica after the second run's origin was lost, so it is the case where the origin is missing nearly everything the phone holds.

### The prefetch, again

8,491 files in 59 minutes 21 seconds. A restart re-verified the complete replica in 31 seconds, and a confirming pass with the import running beside it took 52 seconds. Nothing about the prefetch changed in this run, and it needed nothing.

### The push copied nothing, three times over, and each time it was every file

**A push that copied nothing saved the whole merkle tree once per leaf.** The save every hundred files was `filesCopied % 100 === 0`, which is true at zero, so a pass with nothing to copy wrote a megabyte of tree back after every leaf it looked at. Measured before and after the guard, on the same replica against the same origin:

| | Before | After |
|---|---|---|
| A pass with nothing to copy | 51 minutes, 111 leaves, `treeSaveMs` 3,079,867 | **1.7 seconds, 332 leaves, `treeSaveMs` 0** |

**Every upload declared a Content-Length it then fell 576 bytes short of.** A new line in the HTTP shim says so whenever a request sends fewer body bytes than it declared, and it said so for every file: `declared 41532 body bytes and sent 40956`, always short by exactly the encryption's overhead. The push took each file's length from the store holding it, and an encrypted store's `info` describes the ciphertext on disk while its `readStream` hands out the plaintext. The encrypted target then added the overhead a second time. MinIO waited thirty seconds for a remainder that was never coming, answered "A timeout occurred while trying to lock a resource, please reduce your request rate", the copy was retried three times and abandoned, and the pass moved on to the next file and did the same. About ninety-five seconds a file, and not one byte reached the origin for as long as the sync was left running.

The length cannot be corrected by arithmetic: the format pads the last block to sixteen bytes, and how much of it is padding is known only once it has been decrypted, so the stored size is between 573 and 588 bytes longer than the plaintext and nothing says which. So a store is now asked what a read of it will produce (`readableLength`), every ordinary store answers with the length it reported, an encrypted store answers that it cannot say, and a write given no length declares none and lets the uploader count. The first push after that change:

```
14:05:53  filesCopied 40   bytesCopied 1,808,688  elapsedMs 22,135
14:06:12  filesCopied 80   bytesCopied 3,456,992  elapsedMs 41,490
14:06:53  Push completed: 98 files copied, 0 left behind for the next pass, 0 deleted from target
```

The origin's thumbnail count went from 8,481 to 8,579, which is the 98 exactly. About two files a second for thumbnails, on a connection the import was using at the same time.

**The tree save and the timings line repeated for every leaf walked while the count rested on a multiple.** Both are checked once per leaf, and a leaf whose file is already at the far end copies nothing, so with the count at sixty the same timings line came out five times in a row for leaves 417 to 421. The tree save does the same at every hundredth file, which is the first fault again with a hundred copies in front of it. Both now compare the count against what it stood at when they last ran.

### The whole pass

| Step | Started | Took |
|---|---|---|
| Pull, origin to phone | 14:04:41 | 15 seconds, 0 files copied, all of it diffing |
| Push, phone to origin | 14:04:56 | **1 minute 57 seconds, 98 files copied**, of which the final tree save was 30.6 seconds |
| Merging the phone's records into the origin | 14:06:53 | **14 minutes for 27 records**, at 100% of one core |
| Committing the origin | 14:20:52 | still running at 14:41, when the app was redeployed |

The commit rewrites index files under `.db/bson/indexes/metadata/hash_asc/`, six of them in the nineteen minutes observed, each as a three-part multipart upload of fifteen to twenty seconds. The file copy is now the cheap part of a sync; the record merge and the commit are where the time goes at this scale.

### The import, measured per asset

The upload-asset task reports where its time went. Across the 46 photos and videos it completed between 14:07 and 14:31, about two a minute:

| | A photo | The one video |
|---|---|---|
| `taskMs` | 15,264 to 23,201 | **945,757** (15.8 minutes) |
| `uploadMs`, the write into the replica | 6,489 to 7,847 | 450,583 |
| `otherMs`, unaccounted | about 7,000 | 472,240 |
| everything else together | under 2,000 | 22,900 |

`uploadMs` is the write into the encrypted replica, which is AES-256-CBC in `browserify-aes`, pure JavaScript, at about a fifth of a megabyte a second on this phone. `otherMs` is the read-back: the worker read each written file back out of the store and hashed it to fill the merkle tree, and a stream out of an encrypted store has no file behind it, so the native hasher was skipped and the bytes were decrypted and hashed in JavaScript at the same rate. The read-back was as long as the write it was checking.

The store is not read back any more. The asset's hash is the one the import already had, taken natively from the file before the write, and the thumbnail and display versions are hashed natively from the files they were made into. A store that can say how long its copy reads is checked by length; an encrypted store cannot say and is not checked, which is the same trust the sync places in a store that cannot verify a write.

### Memory

No abort in the 37 minutes the third build ran, with the sync's merge, the sync's commit and the import all running at once. PSS moved between 0.87 and 1.6 GB, nearly all of it native heap (1.26 GB, with the allocator holding 1.9 GB), and `scudo` logged "Can't populate more pages" three times without failing an allocation. The device had 2.6 GB available and most of its swap in use.

### What was fixed during this run

- **A push that copied nothing saved the whole merkle tree once per leaf**, 51 minutes to move no bytes.
- **The sync declared a length it could not know for every encrypted file**, and nothing was ever copied. `readableLength` on `IStorage`, and a write given no length declares none.
- **The tree save and the timings line fired once per leaf while the count rested on a multiple.** Both count per copy now.
- **A request that sends fewer body bytes than it declared says so**, with both numbers and the server's answer. It is what found the fault above in one line, and it stays.
- **The import read every written file back out of the store to learn its hash**, as long again as writing it on an encrypted replica. The hashes come from the files on disk, natively.

### Still open, in order of what it costs

- **AES-256-CBC runs in pure JavaScript on the phone, at about a fifth of a megabyte a second, in both directions.** With the read-back gone it is the whole cost of writing into an encrypted replica: seven seconds a photo, seven and a half minutes for an 87 MB video. Native AES through a host function on both platforms is the lever.
- **The record merge takes fourteen minutes for 27 records**, at full CPU on one core.
- **A commit of the origin rewrites index files of ten megabytes and more, as multipart uploads**, six of them in nineteen minutes for the same 27 records.
- **The engine's native heap sits at 1.3 to 1.6 GB** and the allocator has started saying it cannot get pages. No abort this run, but nothing was changed that would have prevented one.

## The fourth run: what stopped the originals

The third build was left importing overnight. Two things stopped it, and neither was a crash.

### Six hours is all a foreground service gets

At 20:41, six hours after launch, Android timed the `dataSync` foreground service out and the service stopped itself, which is what its `onTimeout` is written to do: an app targeting Android 15 gets six hours of that service type in any twenty-four. The import and the sync were both mid-task and both ended with `InterruptedException`, and the process then sat frozen as a cached process until the morning. Bringing the existing activity back to the front did not restart the service; only a cold start does. By then the phone had imported 1,678 more assets on that build, for a replica of 2,187 originals and 10,661 thumbnails, and the origin held 10,199 thumbnails and the same 250 originals it had started the day with.

So an import that needs more than six hours in a day stops and stays stopped until the user opens the app again. That is the platform's rule and the service already obeys it; what is not there is anything that brings the loop back afterwards.

### The origin was marked partial, so it refused every original

The origin held 250 originals after 1,937 had been imported and pushed because it was refusing them. A push copies only thumbnails and root files into a target whose tree says it is partial, and `psi summary` on the origin said `Mode: partial`. It was made with `psi replicate --full` from the phone's own partial replica, to rebuild an origin that had been lost, and full mode copied the source's metadata across whole, partial flag included. A full replica is full by definition, so full mode now writes the flag as false whatever the source's says, and the origin was rebuilt again with that change into a new bucket, ten minutes for 751 MiB on the same machine, and the phone pointed at it.

### Pushing an original through the databases

With the origin accepting them, the first push of originals measured what the path costs when the bytes are decrypted out of the replica and encrypted again for the origin, both in the embedded engine's JavaScript:

```
20 originals   48,054,976 bytes   472,488 ms   about 100KB/s
```

The network carries 11.8MB/s from this phone. One video then held its upload past the ten minute request timeout and was retried. At that rate the phone's library of originals would take days, and the six hour limit above would cut every one of them short.

Both databases are encrypted under the same key, and for that case there is no need to decrypt anything: the ciphertext the replica holds is exactly the ciphertext the origin would write. A sync now compares the two `.db/encryption.pub` files and, when they are the same, copies the stored bytes between the raw stores untouched, handing the origin a hash of those bytes taken natively from the replica's file, so the upload is one request with the file sent from disk to the socket natively. The first push after that change, on the same phone to the same origin:

```
280 originals   1,042,563,888 bytes   213,771 ms   about 4.9MB/s
```

Fifty times the rate, and the time is now mostly the network's: `writeMs` was 97 seconds of the 214, and the rest was hashing each file natively and the merkle tree diff.

### Two files that fail on every pass

Of the 2,308 items in the library, two failed on every pass of every run. One is a 794-byte Messenger download named `.mp4`, which no tool can read and which the report now names correctly. The other is an animated GIF: ImageMagick writes one file per frame for those, named `-0`, `-1` and so on rather than the name it was given, and the phone looked only for the name it gave, so the resize was reported as "output not created" with an exit code of zero. The desktop already looked for both names; the phone now does too. With that fix in, the GIF imported and the 794-byte file is the only item in the library the phone does not hold.

### The first pass that carried the library

The first sync pass after the change to verbatim copies, with the import finishing beside it and the origin missing nearly every original and display version the phone held:

| Step | Took |
|---|---|
| Pull, origin to phone | 17 seconds, nothing to copy |
| Push, phone to origin | **40 minutes 37 seconds for 3,068 files and 6,482,830,768 bytes**, about 2.7MB/s over the whole pass, 0 left behind |
| Merging the phone's records into the origin | **5 minutes 53 seconds for 500 records** |
| Committing the origin | **4 minutes 19 seconds** |
| The whole pass | **53 minutes 26 seconds** |

The push's own timer says where the 2,437 seconds went:

```
writeMs 745,223   treeSaveMs 1,407,113   treeUpdateMs 127,158   openSourceMs 38,039   diffMs 2,019
```

The uploads themselves were 745 seconds, about 8.7MB/s. **The saves of the merkle tree were 1,407 seconds, more than half the pass.** The tree is saved every hundred files so an interrupted push does not start again from nothing, and on a tree of this size each save is the whole tree, over a megabyte, encrypted in the engine's JavaScript and sent as a multipart upload: 31 saves at about 45 seconds each. Hashing every file natively before it went was 38 seconds for 6.4GB, and updating the tree in memory 127.

The merge went nine times faster than the day before's 14 minutes for 27 records, on the same phone against the same records, with nothing changed in it: the difference is what else the phone was doing, which the day before was the import at full CPU and the read-back of every file it wrote.

### Memory, again

With the read-back gone the fourth build ran at 842MB PSS, of which 736MB was native heap, against 1.3 to 1.6GB the day before, and the allocator said nothing about pages in three hours of importing and pushing at once.

### What was fixed during this run

- **A full replica of a partial one came out marked partial**, so an origin rebuilt that way refused every original pushed at it. Full mode writes the flag as false now.
- **Originals were decrypted and encrypted again on the way to an origin under the same key**, at about 100KB/s. The stored bytes go across as they are, at network speed.
- **The replication's tree save fired per leaf while the copied count rested on a multiple**, the fault the push had, in the code the phone's prefetch runs.
- **Animated GIFs could not be imported on a phone**, because the resize looked for one of the two names ImageMagick writes.
- **A slow open's bookkeeping re-opened a database the user had since closed**, which is what smoke test 45 saw as a menu vanishing from under a tap.
- **The S3 emulator's MinIO is fetched from its GitHub release**, since MinIO archived the project and dl.min.io answers 410 for every release. Not a phone fault, but it took out every S3 test on every CI runner the same morning.

### Still open, in order of what it costs

- **Saving the merkle tree every hundred files is more than half of a big push**: 31 saves of a tree over a megabyte, each encrypted in the engine's JavaScript and sent as a multipart upload, 1,407 of the pass's 2,437 seconds. The save exists so an interrupted push does not start again from nothing, and at verbatim speeds a hundred files is a minute or two of work protected by a forty-five second save. Saving on a clock rather than a count, every few minutes, would bound the loss the same way at a fraction of the cost.
- **Six hours a day is all the foreground service gets**, and nothing brings the loops back afterwards until the app is opened again. The platform's rule stands; what is missing is a way back that does not need the user.
- **AES-256-CBC in pure JavaScript is still every write into an encrypted replica**: seven seconds a photo on import, and every merkle tree save above. Native AES through a host function on both platforms is the lever for what is left.
- **The record merge and the origin commit are minutes each per pass** even with nothing else running: 5 minutes 53 seconds for 500 records here, and a commit that rewrites index files of ten megabytes and more as multipart uploads.
- **An import run that is stopped before its batch fills leaves the batch's originals on the replica's disk and nowhere else.** They are uploaded and processed, then never written to the tree or the import record, so the next run imports them again under new ids and the first copies stay behind as files nothing describes. The service being timed out, the app being redeployed and the phone being restarted each did this once during these runs, and once the last batch had landed the replica held 347 originals, 313 display versions and 500 thumbnails on disk that its tree does not describe. The trade is deliberate and documented at `DATABASE_BATCH_SIZE`; what is not covered is clearing up after it.

### Where it ended

Five passes after the phone was pointed at the rebuilt origin, the origin's tree described 15,491 files, 9.19GiB, and held an object for every one of them: 2,436 originals, 2,300 display versions and 10,754 thumbnails. The phone's tree described nothing the origin lacked, and its import had nothing left to bring in but the one file that is not a photo or a video. The passes that carried it:

| Pass | Started | Pushed | Took |
|---|---|---|---|
| 1 | 12:51:29 | 3,068 files, 6,482,830,768 bytes | 53 minutes 26 seconds |
| 2 | 13:49:55 | 75 files | 15 minutes 31 seconds |
| 3 | 14:10:26 | 795 files, 1,659,670,004 bytes | 25 minutes 44 seconds |
| 4 | 14:41:11 | nothing, 245 leaves walked | 12 minutes 33 seconds |
| 5 | 14:58:44 | 861 files, 892,535,036 bytes | 18 minutes 57 seconds |

Passes 3 and 5 carried the import's last two batches as they landed, and pass 4 ran between them with nothing to carry. Every pass but the first spent most of its time in the record merge and the origin commit rather than in moving files.
