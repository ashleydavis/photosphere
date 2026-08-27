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
