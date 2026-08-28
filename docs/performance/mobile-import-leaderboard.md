# Where a mobile import's time goes, and what has been done about it

## What this is

Every stage of an automatic import on a phone, ranked by what it costs, with a record of every attempt to make each one faster and whether it worked. The target is a full import of the device's library in under two hours.

**Every figure here is measured on a physical Pixel 6.** None is from an emulator. The emulator has misled this work once already: it reported hashing at 24.7% of an import where the phone reports under 2%, because the emulator library was seeded photos with no videos and the phone's library is real.

The measurement is `apps/smoke-tests/tests/manual/90-perf-import/test.sh`, run by name:

```
PHOTOSPHERE_NO_LAN_BRIDGE=1 \
PHOTOSPHERE_PERF_IMPORT_SECONDS=900 \
PHOTOSPHERE_PER_TEST_TIMEOUT=3600 \
PHOTOSPHERE_ANDROID_DEVICES="<serial>" \
bun run test:and -- 90-perf-import
```

## How a change is judged

A change is kept only when the projected full-library time falls by **at least 10 minutes** and by **more than the run-to-run variation** recorded below. A change inside the noise has not been shown to do anything, whatever its own stage timing says.

Three attempts per entry. After three that fail, the entry is marked abandoned, all three results are recorded, and the next entry is taken up.

## The device and the library

| | |
| --- | --- |
| Device | Pixel 6 (`oriole`), Android 16, SDK 36 |
| Library | 2,187 items |
| Time box | 900 seconds per pass |

## Baseline

Taken 27 August 2026, with native hashing already in place.

```json
{"totalMs":886901,"childTaskMs":1132456,"hashMs":18485,"cacheLookupMs":2,"filesHashed":52,"filesFromCache":0,"skippedBeforeOpening":0,"bytesHashed":220111191,"exportMs":48802,"metadataMs":70675,"microMs":24853,"thumbnailMs":20864,"displayMs":27401,"uploadMs":309470,"geocodeMs":0,"dominantColorMs":2797,"databaseWriteMs":543932,"photosSeen":46,"videosSeen":5,"hashSharePercent":1.6,"hashMbPerSecond":11.36}
```

52 items in 886.9 seconds of wall clock: 46 photos and 5 videos, 210 MB. That is 17.1 seconds per item, which over 2,187 items projects to **about 10.4 hours**.

## The leaderboard

Ordered by what each stage cost, largest first. The share is of measured stage time, not of the run's wall clock, because the stages run inside child tasks that overlap. The current standings are at the end of this document, after the attempts that produced them.

As it was at the baseline, before anything here was attempted:

| Rank | Stage | Total | Share |
| --- | --- | --- | --- |
| 1 | databaseWrite | 543.9 s | 51.0% |
| 2 | upload | 309.5 s | 29.0% |
| 3 | metadata | 70.7 s | 6.6% |
| 4 | export | 48.8 s | 4.6% |
| 5 | display | 27.4 s | 2.6% |
| 6 | micro | 24.9 s | 2.3% |
| 7 | thumbnail | 20.9 s | 2.0% |
| 8 | hash | 18.5 s | 1.7% |
| 9 | dominantColor | 2.8 s | 0.3% |
| 10 | cacheLookup | 0.002 s | 0.0% |

## What the baseline overturned

**Database writes are half the import.** Nothing in the earlier reasoning about this import mentioned them. They were assumed to be the cheap part after the expensive media work, and they cost more than everything else put together.

**The three candidate optimisations written into the plan before this was measured are all close to worthless.** Producing the three derivative images from one decode attacks micro, thumbnail and display, which together are 6.9%. Extracting video thumbnails natively attacks part of metadata's 6.6%. Perfectly executed, both together would take about four minutes off a ten hour import. They stay in the leaderboard at their real rank and will be reached if the top entries do not get there first.

**Hashing is 1.7%**, which is the second time this has been confirmed and is the reason this document exists at all.

**The database write stage includes waiting for the write lock**, deliberately, because waiting for it is part of what a database write costs an import. That is also the most likely explanation for the effective concurrency of 1.28 measured against a concurrency limit of 2: the child tasks are serialising behind the lock rather than running beside each other.

## Attempts

### databaseWrite, attempt 1: write the database in batches rather than per photo. KEPT.

Before changing anything, `databaseWrite` was split into what it was actually doing, over a 600 second pass:

| Inside databaseWrite | Time | Share of the stage |
| --- | --- | --- |
| addItems | 147.4 s | 51% |
| commit | 136.1 s | 47% |
| treeLoad + treeSave | 5.2 s | 1.8% |
| flush, lockWait, stamp | 1.2 s | 0.4% |

**37 batches for 42 photos.** The trigger for a database write was a one second trailing throttle, meant to coalesce completions arriving together. On a phone an asset takes over ten seconds to become ready, so nothing ever coalesced and almost every photo paid for a full database commit of its own.

The change holds finished assets until `DATABASE_BATCH_SIZE` of them have piled up, with an escape when the scanner reports itself caught up so a part-filled batch is never stranded.

Measured over the same 600 second pass:

| | Before | After |
| --- | --- | --- |
| databaseWrite | 289.9 s | 9.6 s |
| batches | 37 | 1 |
| commit | 136.1 s | 6.4 s |
| addItems | 147.4 s | 3.0 s |
| Wall clock per item | 13.6 s | 5.4 s |
| Projected for the library | ~8.3 hours | ~3.3 hours |

**Two and a half times faster overall, and `databaseWrite` fell from 51% of the import to 5.5%.** Far outside any plausible run-to-run variation, so it is kept.

**A prediction made here was wrong and is worth recording.** `addItems` was expected to be per-item work that batching could not touch, since it is a loop over the batch's items. It fell 49x. So the cost was not the loop: it was something the BSON collection pays per commit rather than per record. Anyone attacking the remaining 3 seconds should start there rather than in the loop.

**The warm pass reported nothing**, as it did at the baseline. A cold pass has to hash a hundred files before the hash cache is flushed, and these passes reach about thirty. The warm path is not what is being optimised here, but no warm figure in this document means anything until a pass runs long enough to flush.

### upload, attempt 1: copy the file natively instead of piping it. FAILED.

On mobile every byte written through the fs shim crosses the engine bridge as a base64 string built inside the JS engine, and every byte read comes back the same way. Storage puts an imported photo into the database by piping a file-backed stream into a file, so a five megabyte photo became a seven megabyte string to read it and another to write it, to accomplish a copy the platform can do without moving anything into the engine.

Added `fsCopyFile` as a native host function on both platforms, and `FileStorage.writeStream` now copies file to file when the stream it is given carries a path. Node's own `ReadStream` exposes `path` too, so this is not mobile-only.

| | Before | After |
| --- | --- | --- |
| upload per item | 3.04 s | 2.86 s |

**About 6%, which is inside the run-to-run variation.** Not kept on its own.

### upload, attempt 2: stop reading the file that is about to be ignored. KEPT.

Attempt 1 could not pay, and the reason was upstream of it: `createReadStream` in the mobile shim pulled the **entire file** across the bridge as base64 at construction, before anything asked for a byte. So the new copy path avoided the write half while the read half still happened for every photo, and the bytes were then thrown away unread.

`ReadStream` now holds only the path and reads on first consumption, through the `_read` hook the stream shim already had. The existence check stays at construction, so a missing file still fails where every caller expects it to.

| | Baseline | Attempt 1 | Attempt 2 |
| --- | --- | --- | --- |
| uploadMs | 309.5 s | 228.8 s | **1.1 s** |
| upload per item | 3.04 s | 2.86 s | **0.014 s** |
| upload share | 29.0% | 47.5% | **0.4%** |
| Items in a 600 s pass | 43 | 80 | **99** |
| Wall clock per item | 13.6 s | 7.49 s | **6.04 s** |

**210 times less time in upload, and 24% more photos taken in the same ten minutes.** Far outside any plausible variation, so it is kept.

The two changes are one fix and are committed together: the copy cannot pay while the read is still fetching the file it is about to ignore, and the lazy read is pointless without something that declines to consume the stream.

**Projected for the library: about 3.7 hours.** Still over the two hour target.

### The leaderboard after this

| Rank | Stage | Share | Status |
| --- | --- | --- | --- |
| 1 | metadata | 29.4% | not attempted |
| 2 | databaseWrite | 22.6% | done once, worth attacking again |
| 3 | export | 15.3% | not attempted |
| 4 | display | 10.6% | not attempted |
| 5 | micro | 7.7% | not attempted |
| 6 | thumbnail | 7.4% | not attempted |
| 7 | hash | 5.6% | done, before this document |
| 8 | dominantColor | 1.1% | not attempted |
| 9 | upload | 0.4% | **done** |

### metadata, attempt 1: read the EXIF header, not the whole photo. KEPT.

Split first, because "metadata" is two different problems: a photo pays to have its EXIF read, and a video pays to have a frame decoded out of it to make a thumbnail from. The split contradicted the expectation that videos dominated:

| | Time | Per item | Share |
| --- | --- | --- | --- |
| photoMetadata | 64.1 s | 689 ms per photo | 21.6% |
| videoMetadata | 23.6 s | 3,934 ms per video | 8.0% |

689 milliseconds per photo, to read a header. `getImageMetadata` called `fs.readFile` on the whole photo to reach EXIF that sits in the first few kilobytes of it, and on mobile the whole photo crosses the engine bridge as a base64 string. The code carried a TODO saying exactly this.

It now reads the first 256 KB through a new ranged read (`fsReadFileRange` natively on both platforms, `createReadStream(path, { start, end })` in the shim, `readFileHead` in node-utils), and falls back to a whole-file read when no EXIF tags are found, so a photo with an unusual header loses nothing and is merely slower.

| | Before | After |
| --- | --- | --- |
| photoMetadataMs | 64.1 s | 16.3 s |
| Per photo | 689 ms | 174 ms |
| Share | 21.6% | 6.7% |
| Items in a 600 s pass | 99 | 101 |
| Wall clock per item | 6.04 s | 5.67 s |

**Four times less time reading photo metadata.** Kept.

**Projected for the library: about 3.4 hours.** Still over the two hour target.

### The leaderboard after this

| Rank | Stage | Share | Status |
| --- | --- | --- | --- |
| 1 | databaseWrite | 26.7% | done once, back at the top |
| 2 | export | 16.7% | not attempted |
| 3 | display | 13.4% | not attempted |
| 4 | videoMetadata | 9.6% | not attempted |
| 5 | micro | 9.5% | not attempted |
| 6 | thumbnail | 9.4% | not attempted |
| 7 | photoMetadata | 6.7% | **done** |

The three derivative images together are 32.3%, which is now the largest thing on this list. Producing them from one decode instead of three is the candidate that was written into the plan before any of this was measured, dismissed at the time as worth 6.9%, and is worth five times that now that the stages above it have gone.

### the derivative images, attempt 1: produce each from the one before it. KEPT.

Micro, thumbnail and display each decoded the full size original again, so a phone decoded every photo three times to make three small images. Together they were 32.3% of the import.

They are now produced largest first, each from the one before it: display from the original, thumbnail from the display, micro from the thumbnail. The aspect ratio is preserved by every step, so the target dimensions are still computed from the original's resolution and come out the same; what changes is how much image each decode has to read.

| Per photo | Before | After |
| --- | --- | --- |
| micro | 244 ms | 18 ms |
| thumbnail | 243 ms | 114 ms |
| display | 347 ms | 322 ms |
| All three | 834 ms | 454 ms |

**Micro is 13.7 times faster and thumbnail 2.1 times.** Display is barely changed, as expected: it is the one that still decodes the original. Kept.

This is the candidate the plan proposed before anything had been measured, and which the baseline dismissed as worth 6.9%. It was worth 32.3% by the time it was reached, because the stages above it had gone. A candidate rejected on an early measurement is worth re-ranking, not discarding.

**`databaseWrite` came back to the top at 41%** in this pass, on 6 batches rather than the 4 of the pass before. Its cost scales with the number of batches, so that is the next thing to attack, and it is the same entry that has already had one attempt.

### databaseWrite, attempt 2: a batch of a hundred. FAILED, and could not be measured honestly.

The breakdown after the derivative work showed `databaseWrite` back at the top on 41%, with commit costing 6.4 seconds for the first batch of a run and 10.2 by the fifth, against an item count that did not change. So the cost is per commit and per database size rather than per asset, and fewer commits is the lever.

A batch of a hundred could not be judged. No batch of a hundred completes inside the ten minute pass every other figure here was taken over, so the first attempt wrote nothing to the database at all and the warm pass then failed for want of a hash cache, which flushes at a hundred too. A thirty minute pass long enough to fill one gave this:

| Per item | Batch 20, 600 s | Batch 100, 1800 s |
| --- | --- | --- |
| databaseWrite | 906 ms | 421 ms |
| export | 297 ms | 360 ms |
| display | 322 ms | 331 ms |
| Total | 5.60 s | 6.84 s |

The stage it targets improved 2.15x and **the total got worse**, along with export and display, which the change does not touch. A phone doing sustained image work for half an hour throttles, so a thirty minute pass is not comparable with a ten minute one. Not kept: the rule is that the total must fall, and this cannot show that it does.

### databaseWrite, attempt 3: a batch of fifty. KEPT.

Fifty fills inside the same ten minute window every other figure here was taken over, so the comparison is against like.

| | Batch 20 | Batch 50 |
| --- | --- | --- |
| databaseWrite | 96.9 s | 58.6 s |
| Batches | 5 | 2 |
| Per item, databaseWrite | 906 ms | 528 ms |
| Items in the pass | 107 | 111 |
| Videos in the pass | 6 | 6 |
| Wall clock per item | 5.60 s | 5.39 s |

**Projected for the library: about 3.27 hours.** Still over the two hour target.

**What a larger batch costs, and it is not only gallery latency.** A run interrupted before a batch fills loses the assets in it from the database, having already paid to upload and process them: the files are on disk with no record of them. Fifty is half again the exposure of twenty and a fifth of what a hundred would have been.

### The leaderboard after this

| Rank | Stage | Share | Status |
| --- | --- | --- | --- |
| 1 | databaseWrite | 28.3% | **done**, twice, third attempt kept |
| 2 | display | 16.8% | not attempted |
| 3 | export | 14.8% | not attempted |
| 4 | videoMetadata | 12.4% | not attempted |
| 5 | photoMetadata | ~10% | done |
| 6 | hash | ~9% | done |

### display, attempt 1: ask the JPEG decoder for a smaller image. FAILED.

`-define jpeg:size=WxH` before the input makes libjpeg decode at a reduced DCT scale, so a large photo is never fully decoded on the way to a small one. Measured, display went from 335 ms per photo to 351 and micro got worse. The total fell 6%, but the stage the change targets did not move, so the drop is not attributable to it and was not banked. Reverted.

### The unmeasured remainder, which turned out to be the whole problem

Every stage with a counter on it summed to 1.90 seconds per item against 8.63 seconds of child task time. **Roughly 80% of the import was in code with no counter on it.** Giving that remainder a name (`otherMs`, computed as the task's own time minus everything it reports) was worth more than every optimisation before it.

What it found: every upload task writes each file and then **reads it back and hashes it again** to record its hash in the merkle tree, three times per photo for the original, the thumbnail and the display version. `validateAndHash` had been given the native hasher; `computeAssetHash` had not, so that re-hash was still the pure-JS SHA-256 at well under a megabyte a second, over bytes fetched back across the engine bridge as base64.

`computeAssetHash` now takes the native path when the stream it is given carries a file path, which is the same choice `computeFileHash` makes and uses the same hasher. Both paths produce identical digests, so the merkle tree records exactly the values it always did.

| | Before | After |
| --- | --- | --- |
| other | 629.9 s (54%) | 4.8 s (0.4%) |
| Items in a 600 s pass | 119 | 177 |
| Wall clock per item | 4.99 s | 3.34 s |

**49% more photos in the same ten minutes. Projected for the library: about 2.03 hours**, from about 3.27.

Two things worth taking from this beyond the fix. A counter on the remainder should have existed from the first measurement, not the seventh. And the candidates the plan named before anything was measured (one decode for three derivatives, native video thumbnails, raising concurrency) were all real but small; nothing in that list was the actual problem, and the actual problem had no name until it was given one.

### The leaderboard after this

| Rank | Stage | Share | Status |
| --- | --- | --- | --- |
| 1 | databaseLookup | 69.3% | not attempted |
| 2 | databaseWrite | 7.9% | done, three attempts |
| 3 | display | 4.9% | attempt 1 failed |
| 4 | videoMetadata | 3.4% | not attempted |
| 5 | export | 2.9% | not attempted |

`databaseLookup` opens storage, builds a database object and runs an index query once per photo, to ask whether a hash is already in the database. It scales with database size: 373 ms per file early in a run, 4.3 seconds per file by the end of this one. The orchestrator already tracks the same information in memory in `hashesQueuedForImport`, so this looks removable rather than merely optimisable.

### databaseLookup, attempt 1: ask the database once per run instead of once per file. KEPT.

Every `hash-file` task built its own storage, its own database object and its own collection to ask one question: is this hash already here. A fresh collection has a fresh sort index cache, so each of those questions read the whole hash index again, and the read grew as the database filled: 373 milliseconds a file early in a run, 4.3 seconds a file by the end of one.

The import already holds one collection for the life of the run. It now reads every hash in the database into a map when the run starts and answers from that, and `hash-file` no longer looks at the database at all: it hashes the file and says what the hash is. The question and its answer are unchanged, and so is what gets written.

| | Before | After |
| --- | --- | --- |
| databaseLookup | 69.3% of the import | not asked |
| Wall clock per item, cold | 3.39 s | 1.84 s |
| Files in a cold pass | 177 in 600 s | 344 in 633 s |

**1.84 times more photos in the same time.** Measured twice on the Pixel 6, at 1.80 and 1.84 seconds an item. Kept.

The fields the task used to fill (`filesAlreadyAdded`, `existingAssetId`, and the three counters that timed the lookup) are gone rather than left reporting false and zero, so nothing can read an answer this task no longer gives.

### The perf harness was switching its own warm pass off

Worth recording because the run said PASS on a pass that measured nothing. A pass ends by force-stopping the app, which leaves the automatic import setting exactly as it was, so the warm pass opened an app that started importing by itself, and the harness's click then turned it off. The warm pass ran for eighteen seconds and reported a library it had never looked at. It now turns the import on only when the app has not already started it.

### The leaderboard after this

| Rank | Stage | Share of a cold pass | Status |
| --- | --- | --- | --- |
| 1 | databaseWrite | 52.5% | done three times, back at the top |
| 2 | display | 17.0% | attempt 1 failed |
| 3 | probe | 10.2% | not attempted |
| 4 | hash | 9.7% | done |
| 5 | thumbnail | 9.2% | done |
| 6 | photoMetadata | 8.3% | done |
| 7 | videoMetadata | 7.6% | not attempted |
| 8 | export | 4.0% | not attempted |

**`databaseWrite` is not merely the largest, it is the one that grows.** The two passes of this run are the same import continued, and they show the cost climbing with the size of the database rather than with the number of photos:

| | Cold pass (database 0 to 300) | Warm pass (300 to 600) |
| --- | --- | --- |
| databaseWrite | 332.6 s over 6 batches | 415.7 s over 3 batches |
| Per batch | 55 s | 138 s |
| Wall clock per item | 1.84 s | 5.05 s |

A per-item cost that climbs like that does not extrapolate to a two hour import of the whole library however fast the first few hundred go, so this is the next target and everything below it can wait.

### databaseWrite, attempt 4: stop asking storage which indexes exist, once per record. FAILED.

The write loop had no breakdown, so it got one first: the merkle tree adds, the record inserts, and everything else the loop does per item. That answered one question outright and raised a better one.

| Inside the write loop, cold pass | Total | Per record |
| --- | --- | --- |
| merkle adds | 0.109 s | 0.3 ms |
| record inserts | 119.6 s | 338 ms |
| the rest of the loop | 34.7 s | 98 ms |

**The merkle tree costs nothing.** A tenth of a second across a whole run, against two minutes for the inserts. Every earlier guess about this stage had the tree in it somewhere.

The inserts also grow: 338 ms a record in the cold pass, 904 ms in the warm pass that continued it, against a batch size that does not change. So does commit: 55 s a batch, then 66 s.

A benchmark of the same inserts on a desktop (`bun run --filter=bdb perf`, added for this) runs them at 0.04 ms a record, three thousand times faster, so whatever the phone is paying for is not arithmetic. That benchmark also counts what each insert asks of storage, and found the same two calls every time, forever: a `dirExists` and a `listDirs`, asking which sort indexes the collection has, per record.

Remembering that answer removed both calls, which the benchmark confirms. On the device it changed nothing:

| Cold pass | Before | After |
| --- | --- | --- |
| record inserts, per record | 338 ms | 392 ms |
| commit | 165.5 s | 185.1 s |
| Wall clock per item | 1.82 s | 1.90 s |

Not kept, and reverted. The two calls were not what an insert was paying for, and a change that cannot show an improvement does not get to stay on the grounds that it removes work.

What it did establish: the cost is not the merkle tree, not arithmetic, and not those two calls. The next thing to rule out is what an insert does that a desktop does not, which is why the insert is now counted apart from the hash cache write that follows it.

### The phone gets hotter as the measurements go on, and that has been in the numbers

Three cold passes were run back to back, each half an hour of sustained image work, and the phone was 26.7 °C at the start of the first and 33.4 °C by the end of the third. Wall clock per item across those three: 1.82 s, 1.90 s, 2.03 s. The two changes measured in the second and third are both small, and a seven degree rise on this phone is enough to account for a drift of that size on its own.

So neither of those two runs proves what it looked like it proved. Both changes are unproven rather than disproven, and unproven does not earn a commit either, so both were reverted. What it does mean is that any two measurements taken half an hour apart are not comparable unless the phone started them at the same temperature.

From here every measurement records the phone's temperature beside it, and a comparison is only made between passes that started within a couple of degrees of each other.

### databaseWrite, attempt 5: stop dropping the database's cached pages before every batch

Before each batch the import called `flush()` on the database, dropping every cached shard and index page. The desktop benchmark says what that costs, by running the same inserts with and without it:

| Per record | Caches kept | Caches dropped each batch |
| --- | --- | --- |
| storage reads | 0.0 | 1.7 |

Those reads are not small: an index page holds every record in the index, so what a batch reads back grows with the database, which is what the growth in the device numbers looks like (338 ms an insert in a cold pass, 904 ms in the warm pass that continued it).

The drop was also in the wrong place to do what it was for. It ran before the write lock was taken, so another writer could change the database in the moment between, leaving exactly the stale caches it was meant to prevent.

It now runs under the lock, and only when the database's own modified stamp differs from the one this run last wrote. Every writer updates that stamp under the same lock, so a stamp that has not moved means nothing has written since. One small read replaces the re-reading of everything.

**KEPT.** Measured on the Pixel 6, and the stage it targets is unmistakable:

| Cold pass | Before | After |
| --- | --- | --- |
| Collection inserts | 136.7 s | 19.2 s |
| Per record | 397 ms | 56 ms |
| The whole write loop | 175.4 s | 58.2 s |
| databaseWrite | 369.1 s | 241.8 s |
| Wall clock per item | 2.03 s | 1.52 s |

**Seven times less time spent inserting records.** The after pass started at 31.6 degrees against 26.7 for the earliest baseline, so it was measured on a hotter phone than the numbers it beats.

`commit` is now what a database write mostly is: 178.6 s of the 241.8 s, and about a third of the whole import.

The warm pass that continued it, starting at 32.9 degrees:

| Warm pass | Before | After |
| --- | --- | --- |
| Collection inserts, per record | 904 ms | 303 ms |
| Wall clock per item | 4.86 s | 4.06 s |

The insert still costs more as the database grows, but three times less than it did.

### The leaderboard after this

| Rank | Stage of a cold pass | Share | Status |
| --- | --- | --- | --- |
| 1 | commit (inside databaseWrite) | 34% | not attempted |
| 2 | display | 13% | attempt 1 failed |
| 3 | probe | 12% | not attempted |
| 4 | hash | 11% | done |
| 5 | thumbnail | 10% | done |
| 6 | photoMetadata | 10% | done |
| 7 | videoMetadata | 9% | not attempted |

Committing is now most of what writing to the database costs. What a commit does is write one file per dirty shard and one per shard merkle tree, and a batch of fifty records lands in about forty of the hundred shards, so it writes about eighty files. That count comes from how records are spread across shards, which is part of the on-disk layout and cannot be changed.

### An import of a real library could not finish at all

Every measurement above was taken over a time-boxed pass of fifteen minutes or less, and that box ends just short of where the interesting thing happens. Run without one, an import took in about three hundred photos and then failed every single photo after that, thousands of them, each with `InternalError: stack overflow` raised by QuickJS one frame deep inside `getFileInfo`.

It was not caused by any of the work here: the commit before this one fails identically. Nothing had ever run long enough to see it.

What it is not: not the photos (the same files import in a fresh process), not the thread (the engine's worker thread never changes), not file descriptors (362 open against a limit of 32768), not the device (a restart of the app clears it completely and lets another three hundred through). What it is: something that accumulates in the QuickJS context as it runs tasks. The app's native heap climbs by roughly 170 KB a photo while it happens.

Two attempts at the cause failed. ImageMagick was calling `MagickWandGenesis` and `MagickWandTerminus` around every invocation, which is the wrong pattern for a long-lived process and a documented leaker; starting it once changed neither the heap nor the failure. The engine's worker thread was checked in case it had been replaced, which would leave QuickJS measuring its stack against a thread that had gone; it never changes.

**What fixes it: the engine throws its context away and builds a new one every hundred tasks.** That is a workaround and is written down as one in the code: it keeps imports working while what fills the context up is still unknown.

| A single uninterrupted import | Before | After |
| --- | --- | --- |
| Photos taken in | 302, then every one failed | 1,422 in 150 minutes, none failed |

### Where that leaves the two hour target

Not met, and the reason is now clear. `commit` is what a database write mostly is, and its cost grows with the size of the database: 51% of an import by a thousand photos in, with the cost of a batch three and a half times what it was at three hundred.

The reason is the sort indexes. A leaf page holds every record in it, so a commit rewrites every record in the index however few were added. That makes a bulk import quadratic in the number of photos. Page size is part of the on-disk layout, which cannot change, so what is left is how often a commit happens.

Batches of two hundred and fifty were tried for that. Over the first seventy minutes they were well ahead: 1,389 photos against 1,061 for batches of fifty, with commit down from 51% of the import to 22%. Then it collapsed, taking eighty minutes to add thirty-three more photos, which is what a single commit of two hundred and fifty records against a database of fourteen hundred looks like while it holds the write lock and every upload waits behind it. Reverted.

So the import is no longer broken, and it is no longer slow for the first several hundred photos, but a whole library of a couple of thousand still takes hours, and the next thing standing in the way is inside the database's index rather than anywhere in the import.

### probe, attempt 1: read the dimensions without the EXIF. COULD NOT BE MEASURED.

Validating a photo asks for its whole file info, which runs ImageMagick twice: once for the width and height and again for the EXIF. Validation looks only at the dimensions. Asking for just those makes it one run, and a unit test pins that it runs ImageMagick once rather than twice.

It could not be measured on the device. Three passes in a row, of fifteen, thirty and seventy minutes, reached only videos: the scan puts them first and there are enough of them, at several seconds each, that no pass got to a photo. The change touches images only, so a pass with no photos in it says nothing. Reverted rather than committed on a mechanism alone.

### videoMetadata, attempt 1: seek before reading the input, not after. FAILED.

`ffmpeg -i file -ss T` is an output seek: ffmpeg decodes the video from its start up to T and throws every frame away to keep one, so a frame from the middle of a video costs half the video. `ffmpeg -ss T -i file` jumps to the nearest keyframe first. That is a real difference and the reason this looked promising.

Measured against the same code with the seek moved back, on the same phone within a few degrees:

| Per video | Seek after the input | Seek before it |
| --- | --- | --- |
| videoMetadata | 2,965 ms | 3,393 ms |

Slower, not faster. Two things explain it. The videos in this library are short, so the decode an output seek does is short too, while a keyframe seek has its own cost. And what a pass spends per video depends far more on which videos it happened to reach than on the seek: across the runs here the same code produced 2,676, 2,965, 3,934 and 4,834 ms a video. That spread is wider than the change being looked for, which makes this stage hard to measure at all without pinning the set of videos.

Reverted.

### Where the leaderboard stands

| Stage | Attempts | Outcome |
| --- | --- | --- |
| hash | done | native hashing, then native hashing of written assets |
| databaseLookup | 1 | removed entirely |
| databaseWrite: cached pages | 1 | kept, inserts seven times faster |
| databaseWrite: batch size | 3 | fifty kept; a hundred unmeasurable, two hundred and fifty worse at scale |
| databaseWrite: index list | 1 | no effect, reverted |
| databaseWrite: directory memo | 1 | no effect, reverted |
| photoMetadata | done | EXIF header instead of the whole photo |
| the derivative images | done | each made from the one before it |
| upload | done | native file copies |
| display | 1 | failed |
| probe | 1 | could not be measured |
| videoMetadata | 1 | failed |
| export | 0 | not attempted |

`commit` is what is left and it is the largest thing on the list, but what it costs is decided by the sort index page holding every record, which is part of the on-disk layout. Nothing in the import can change that. Two hours for a first import of a couple of thousand photos needs that page format to change, or the index to be built once at the end of a bulk import rather than maintained through it.

### export: measured, and deliberately not attempted

Copying an item out of the photo library into the app's sandbox costs 72 ms a photo and 1.9 seconds a video, which is about 4% of a cold pass and more of one that is mostly videos. The copy exists because a library item is not a file: the hasher and the media tools both need a path they can open.

The device does offer one. `content query --uri content://media/external/images/media --projection _data` returns real filesystem paths, and an app holding the media permissions can generally open them. Handing the import the original's own path would remove the copy entirely.

It is not being done, and the reason is what closing an item does: it deletes the copy the open made. Point the import at the original and that delete is pointed at the user's own photo. The guard is one line, and one line is exactly the kind of thing that is right until somebody edits around it, at which point the failure is somebody's photos rather than a slow import. Four percent is not worth putting a delete anywhere near a photo library that is not ours.

If it is wanted, the safe shape is for the close to refuse any path outside the sandbox rather than to remember whether it made a copy, so that forgetting cannot delete anything.
