# The automatic import scan on Android, cold cache and warm

## What was measured

How long automatic import takes to read a photo library, and what the hash cache is worth once it has read it. Two runs back to back: the first with the hash cache deleted, so every item is exported out of the library and hashed, and the second straight after it against the cache the first one left behind.

Nothing was imported. No database was opened or written, no thumbnail or display version was generated, and no photo on either device was added, changed or removed.

Measured twice: on an emulator with a synthetic library, and on a real phone with a real one. The phone is the number that matters; the emulator run is here because it is what the measurement was built against.

## The phone

- Device: Pixel 6 (`oriole`), Android 16.
- Library: 2,186 photos, 2.60 GB, averaging 1.22 MB each.
- Date: 24 August 2026.
- The cold run was time-boxed to ten minutes rather than left to walk the whole library, and the warm run then covered exactly the items the cold run reached. The full-library figures below are extrapolated from that sample and are marked as such.

### Raw results

Cold run, hash cache deleted first, stopped at its ten minute limit:

```json
{"itemsSeen":159,"cacheHits":0,"cacheMisses":159,"bytesHashed":488390348,"failures":0,"listingMs":60,"exportMs":5144,"hashMs":618583,"cacheLookupMs":17,"totalMs":624188,"stoppedEarly":true}
```

Warm run, immediately after, over the same 159 items:

```json
{"itemsSeen":159,"cacheHits":159,"cacheMisses":0,"bytesHashed":0,"failures":0,"listingMs":48,"exportMs":0,"hashMs":0,"cacheLookupMs":15,"totalMs":63,"stoppedEarly":true}
```

### Summary of the sample

| Measure | Cold run | Warm run | Warm vs cold |
| --- | --- | --- | --- |
| Items seen | 159 | 159 |  |
| Cache hits | 0 | 159 |  |
| Cache misses | 159 | 0 |  |
| Failures | 0 | 0 |  |
| Megabytes hashed | 465.77 | 0.00 |  |
| Elapsed seconds | 624.19 | 0.06 | 9907.75x faster |
| Items per second | 0.25 | 2523.81 | 9907.75x |
| Megabytes per second | 0.75 | 0.00 | 0.00x |
| Listing | 0.0% | 76.2% |  |
| Export | 0.8% | 0.0% |  |
| Hashing | 99.1% | 0.0% |  |
| Cache lookup | 0.0% | 23.8% |  |

### The whole library, extrapolated

**A cold pass over all 2,186 photos would take about one hour. The warm pass that follows it takes about a second.**

The extrapolation is by bytes, not by photo count, because hashing is 99% of the cost and hashing is proportional to bytes:

- Hashing: 618,583 ms for 465.77 MB is 1,328 ms per MB. Over 2,662 MB that is 3,536 seconds.
- Export: 5,144 ms for 159 items is 32 ms per item. Over 2,186 items that is 71 seconds.
- Listing and cache lookups are tens of milliseconds and do not matter.
- Total: roughly 3,607 seconds, so about 60 minutes.
- Warm: 63 ms for 159 items scales to about 0.9 seconds for 2,186.

**Do not extrapolate this by photo count.** The ten minute sample happened to cover photos averaging 2.93 MB, against the library's overall average of 1.22 MB, so scaling its 0.25 photos per second to the whole library overstates the time by about 2.4x. Megabytes per second is the figure that carries across libraries; photos per second is not.

## The emulator

- Device: Android emulator, `sdk_gphone64_x86_64`, Android 14 (API 34), x86_64.
- Library: 200 copies of `test/test.jpg`, 2,049,800 bytes each, 409,960,000 bytes (390.97 MB) in total.
- Date: 23 August 2026.
- The whole library, not a sample.

Cold run:

```json
{"itemsSeen":200,"cacheHits":0,"cacheMisses":200,"bytesHashed":409960000,"failures":0,"listingMs":58,"exportMs":2896,"hashMs":344095,"cacheLookupMs":18,"totalMs":347391}
```

Warm run:

```json
{"itemsSeen":200,"cacheHits":200,"cacheMisses":0,"bytesHashed":0,"failures":0,"listingMs":50,"exportMs":0,"hashMs":0,"cacheLookupMs":8,"totalMs":58}
```

| Measure | Cold run | Warm run | Warm vs cold |
| --- | --- | --- | --- |
| Items seen | 200 | 200 |  |
| Cache hits | 0 | 200 |  |
| Cache misses | 200 | 0 |  |
| Failures | 0 | 0 |  |
| Megabytes hashed | 390.97 | 0.00 |  |
| Elapsed seconds | 347.39 | 0.06 | 5989.50x faster |
| Items per second | 0.58 | 3448.28 | 5989.50x |
| Megabytes per second | 1.13 | 0.00 | 0.00x |
| Listing | 0.0% | 86.2% |  |
| Export | 0.8% | 0.0% |  |
| Hashing | 99.1% | 0.0% |  |
| Cache lookup | 0.0% | 13.8% |  |

The emulator manages 1.13 MB/s against the phone's 0.75, so it is about 1.5x faster. The split between the stages is the same on both to within a tenth of a percent, which is the part that generalises.

## What the numbers say

**A cold scan is entirely hashing.** 99.1% of it, on both devices. Copying photos out of the photo library, which is the part that sounds expensive on a phone, is 0.8%. Listing the whole library is tens of milliseconds. Nothing else is worth looking at until hashing is dealt with.

**The phone hashes at 0.75 MB/s.** That is what sets the hour. Content hashing in the embedded worker goes through `create-hash`, a pure-JS SHA-256, running inside QuickJS. There is no native hashing host function: `CryptoHost.java` implements RSA key generation, signing, and OAEP encrypt/decrypt, and nothing else. A Pixel 6's own SHA-256 runs at hundreds of megabytes a second, so a native hashing host function would take the hour down to seconds. It is the single change that would move this number, and nothing else comes close.

**A warm scan costs almost nothing.** About a second for the whole library, against an hour cold. The cache is consulted using the item's source id, size and created time, all of which the listing already reports, so a hit avoids exporting the photo as well as hashing it. What is left is the listing itself and one cache lookup per item. This is the path a photo the app has already taken in follows on every subsequent run, which is why it is the one that matters for a phone doing this repeatedly.

**Read the ratio as "milliseconds rather than minutes", not as a number.** The warm run is so short that its total is close to the resolution of what is being timed, so the 9,907x in the table is arithmetic rather than a measurement.

## What this measurement found

**The hash cache never persisted on mobile at all.** The first attempt reported 200 cache misses on the warm run as well as the cold one, having done all the work twice. The cause was that `packages/mobile-worker/src/shims/node-fs-promises.ts` had no `open`. Every read-modify-write of a shared file goes through `updateFileRawOptimistic` in `packages/node-utils/src/lib/fs.ts`, which takes an exclusive lock with `fs.open(lockPath, 'wx')`. On mobile that was `undefined`, so the call threw a `TypeError`, which travelled up to `HashCache.save()` and was swallowed by its bare `catch`. The cache directory was created and left permanently empty.

The effect on the product was that every automatic import re-exported and re-hashed every photo it had already imported, on every run, for ever, and nothing anywhere said so. On the phone's numbers that is an hour of work per run that should have cost a second.

`open` has been added to the shim for the exclusive-create flags only, built on the same native call `writeFile` already uses, which raises `EEXIST` when the file exists. Any other flag throws and names what is missing rather than pretending to work.

The check that the warm run's cache hits equal the items it saw is the assertion that caught this, and it is in the smoke test for exactly that reason.

**The scan stops when the screen goes off.** Observed on the phone: the cold pass was saving a batch of 100 every five to six minutes, the screen turned off, and nothing was written for the following eight minutes. There is no foreground service, so the work is suspended with the app. Automatic import today only progresses while the app is on screen.

## What a native hasher would be worth, and what a Zig port would not

Native SHA-256 was measured on the same Pixel 6, for comparison against the 0.75 MB/s the scan manages: `sha256sum` over a 46.45 MiB system file took 0.09 seconds on a cold read and 0.05 on a warm one, which is 500 to 900 MB/s. That is roughly 700 times the rate the embedded worker hashes at.

Applying that to the full library, and leaving the export alone because it is already native work done by Android's ContentResolver:

| Stage | Now | With native hashing |
| --- | --- | --- |
| Hashing | 3,536 s | ~5 s |
| Export out of the photo library | 71 s | 71 s |
| Listing and cache lookups | <1 s | <0.1 s |
| Cold pass total | ~60 min | ~80 s |

So about 45x on a cold pass, and the warm pass goes from about a second to a few milliseconds.

**Almost none of that is a language question.** The gap is between a pure-JS SHA-256 running in an interpreter and a native one; it is not between TypeScript and something faster. A native hashing host function added beside the RSA functions already in `CryptoHost.java` would collect virtually the whole 45x while leaving the rest of the code in TypeScript.

This is worth stating because the published figures for converting this project's `what-changed` tool from TypeScript to Zig (https://github.com/ashleydavis/what-changed/blob/main/docs/performance.md) are 6x to 10x on hashing, and they do not transfer here. That comparison is Bun-hosted TypeScript against Zig, and **both** of those use a native SHA-256, so the 6x to 10x measures startup, IO and orchestration rather than the hash. The equivalent parts of this scan, the listing and the cache lookups, are 2% of a cold pass, so rewriting them in any language buys about a second.

After a native hasher lands, the export becomes the bottleneck: 71 of the remaining 80 seconds. Nothing about the language changes that, so roughly 45x is the ceiling for this code path however it is rewritten.

## What is not measured here

- No thumbnail, no display version, no database write, no upload. The import does all of those after the point this stops at, and on a phone the derivative generation is expected to dominate again.
- The export out of the photo library happens on a cold run only. It is not what the cache saves directly; the cache saves it as a consequence of answering before the export is needed.
- Videos. Both libraries are photos. Video files are much larger, so the megabytes-per-second figure is the one to carry across.
- The phone's full library end to end. Only a ten minute sample of it was run; the hour is arithmetic on that sample.

## How to run it again

**The measuring code is not in the tree.** It was written in a scratch worktree, used to take the numbers above, and discarded, because it is test-only scaffolding in app code that nothing else should carry: a `perf-scan` worker task, a `perf-scan` command in the shared test driver and control bridge, and a smoke test to drive them. What follows describes what it did, so it can be rebuilt if the measurement is wanted again.

The task walked the device library through `DeviceMediaSource`, asked `HashCache` about each item using its source id, size and created time, and for a miss exported the item and ran `validateAndHash` over the copy, saving the cache every hundred entries. It reported items seen, cache hits and misses, bytes hashed, failures, and elapsed milliseconds split by listing, export, hashing and cache lookup. It took an optional time or item budget so a run could be a timed sample rather than a full pass. The smoke test deleted only the hash cache, ran the task twice, and asserted that the cold run missed on every item and the warm run hit on every item.

It lived at `apps/smoke-tests/tests/manual/90-perf-scan/test.sh`, under `tests/manual/` so that a normal run never performed it, and it was invoked by name with a per-test timeout raised well above the ten minute default:

The whole library:

```
PHOTOSPHERE_PERF_SCAN_TIMEOUT=10800 PHOTOSPHERE_PER_TEST_TIMEOUT=25200 PHOTOSPHERE_ANDROID_DEVICES="<serial>" bun run test:and -- 90-perf-scan
```

A ten minute sample of it, which is how the phone figures above were taken:

```
PHOTOSPHERE_PERF_SCAN_COLD_SECONDS=600 PHOTOSPHERE_PERF_SCAN_TIMEOUT=1200 PHOTOSPHERE_PER_TEST_TIMEOUT=3600 PHOTOSPHERE_ANDROID_DEVICES="<serial>" bun run test:and -- 90-perf-scan
```

It reads the library and deletes one directory of its own, the hash cache. It never seeds or removes a photo, and it refuses to run while automatic import is switched on, because an import running beside it would take the device's photos into a database and throw the numbers out.

Two things to know before pointing it at a real phone. The screen has to stay on for the whole run, or the scan stops. And the smoke test runner clears the app's data at the end of a run (`android_cleanup` in `apps/smoke-tests/lib/android.sh`), which removes the app's databases and settings, though nothing outside the app.
