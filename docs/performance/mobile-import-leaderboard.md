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
