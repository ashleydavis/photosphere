# Native hashing on mobile: automatic import before and after

## Status

**In progress.** This document is being written as the work happens rather than assembled from notes at the end, so the sections below are filled in as each figure lands. Anything not yet measured says so; nothing here is estimated and presented as measured.

| Stage | State |
| --- | --- |
| Method settled | Yes, described below |
| Measuring harness built | Yes, `apps/smoke-tests/tests/manual/90-perf-import/` |
| Before figures taken | Yes, on an emulator. **Not on the phone** |
| Native hashing implemented | Yes, Android and iOS |
| After figures taken | Yes, on an emulator. **Not on the phone** |
| Decision | **Short of the bar on every measurement taken. The phone run settles it and is still owed.** |

**Two headline findings, both of which contradict what the earlier scan measurement led people here to expect.**

**Hashing is 24.7% of a full import, not the 99.1% it is of a bare scan.** A scan lists, exports and hashes; a full import also decodes each photo, builds a thumbnail and a display version, and writes to the database. That is three quarters of the work and no amount of faster hashing touches it.

**Native hashing made hashing 11.6x faster and the import 1.24x faster.** Both numbers are real and neither is marginal. The bar agreed in advance was several times faster on a phone. See "The decision".

## The question this answers

Automatic import on a phone hashes every photo with a pure-JS SHA-256 running inside the embedded JS engine. A native hash is available on both platforms and is far faster in isolation. The question is not whether native SHA-256 is faster than JS SHA-256, which is not in doubt, but **whether routing the import's hashing through it makes automatic import on a real phone substantially faster end to end**.

That distinction is the whole point of measuring. Hashing is 99.1% of a bare scan of the photo library, but a full import also generates a thumbnail and a display version for every photo and writes to the database, and none of that has ever been measured. If hashing turns out to be a small part of a full import, this change will collapse the hashing time to nothing and barely move the number a user waits on.

**The change is kept only if the full import gets substantially faster on the phone, and reverted if it does not.**

## What is measured

A **full automatic import**, end to end: listing the device photo library, exporting each photo out of it, hashing, generating the thumbnail and display version, and writing to the database. Not a scan. The total is the figure the decision turns on.

**Hashing is reported separately inside that total**, so the change can be seen doing what it claims to do even in the case where the total barely moves. If hashing collapses and the total does not, that is a finding worth having, and it says the bottleneck is somewhere this change does not reach.

Two passes, both before and after:

- **Hash computed (cold).** The hash cache is deleted first, so every photo is exported out of the library and hashed. This is the pass the change is aimed at, and it is what a first backup of a phone does.
- **Hash cached (warm).** Run straight after the cold pass, over the items the cold pass reached. The cache answers, so nothing is exported and nothing is hashed. This is what a phone does on every run after the first. It is measured because a change that speeds up the cold pass while slowing the warm one down has not helped.

## Why the measurement is time-boxed rather than run over the whole library

A cold pass over the phone's whole library cannot be run twice in a working session, and would have to be run four times here (cold and warm, before and after).

From the earlier scan measurement in `mobile-auto-import-scan.md`: a cold **scan** of the library, which is listing, exporting and hashing and nothing else, extrapolates to about an hour. The same document records an end-to-end import observed at about 1.5 photos a minute, which over a library that size is around a day. That observation was taken while the phone was out of swap and is not a figure to rely on, but it is the right order of magnitude for the point being made here: a full cold import of the whole library is not a measurement that can be repeated four times.

So each pass is **time-boxed to a fixed wall clock**, and what is compared is the rate and the split between the stages rather than a total for the whole library. The warm pass then covers exactly the items the cold pass reached. This is the same method the earlier scan measurement used, for the same reason, and it is what makes the before and after comparable: both are run for the same length of time on the same device against the same library.

The time box is chosen when the harness is built and is recorded here with the figures, because a before and an after taken over different time boxes are not comparable.

## The device and the library

The decision figure has to come from a real phone. The earlier scan measured an emulator at about 1.5x the phone's hashing rate, and a phone is what the product runs on.

**The figures below are from an emulator, because the Pixel 6 was not attached when they were taken.** They are recorded as what they are. The split between hashing and everything else is the part that generalises, and it is that split, not the absolute rate, that the finding below rests on. The phone run is still owed.

| | |
| --- | --- |
| Device, before run | Android emulator, `sdk_gphone64_x86_64` |
| Library, before run | 24 photos, 49,195,872 bytes (46.9 MB), each a distinct file |
| Time box | 420 seconds a pass; both passes finished well inside it |
| Device, after run | Android emulator, `sdk_gphone64_x86_64`, same device and library as the before run |

The photos are distinct on purpose. An earlier attempt seeded 24 identical copies of one file, and the import hashed all of them but then recognised 23 as duplicates by content and imported one, so almost none of the thumbnail, display-version and database work a real import does was measured at all.

## The harness

`apps/smoke-tests/tests/manual/90-perf-import/test.sh`, run by naming it. It is under `tests/manual/`, which the runner reaches only when a test is named, so an ordinary run never performs it.

It wipes the app's stored data (which is what makes the cold pass cold), grants the photo and notification permissions from outside the app, switches automatic import on through the settings card, and waits. Each pass gets a time box: a library small enough to finish inside it ends on its own, and one too big is stopped by switching automatic import off, which makes the run in flight report what it got through. Then it does it again against the hash cache the first pass left.

What it reads is the `Import timings:` line every import writes as it ends. That line is sent from the import task as a message and logged by the app, because the import runs inside the embedded JS engine whose own log output never reaches the app log.

```
PHOTOSPHERE_PERF_IMPORT_SECONDS=1200 \
PHOTOSPHERE_PER_TEST_TIMEOUT=3600 \
PHOTOSPHERE_ANDROID_DEVICES="<serial>" \
bun run test:and -- 90-perf-import
```

Two things to know before pointing it at a real phone.

The run does not need the screen kept on. Automatic import is driven by `AutoImportService`, an Android foreground service, so it keeps working while the phone is idle and off screen. (`docs/performance/mobile-auto-import-scan.md` says the opposite under "What this measurement found". That was true of the scan harness it describes and is no longer true of automatic import.)

Sideloading onto a phone needs **Developer options → Verify apps over USB** turned off (`adb shell settings put global verifier_verify_adb_installs 0`). Without it Play Protect sends each install of an unrecognised package off for verification and either refuses it (`INSTALL_FAILED_VERIFICATION_FAILURE`) or waits for someone to tap "Install anyway" on the phone, which makes an unattended run impossible.

The smoke test runner clears the app's data when the run ends, which removes the app's own databases and settings and nothing outside the app. The device's photo library is never written to.

### Reading the figures

`hashMs` and `childTaskMs` are summed over child tasks that run concurrently, so they add up to more than the run's wall clock and **hashing is a share of `childTaskMs`, never of `totalMs`**. A share of the wall clock would change with how many tasks the device runs at once, which would look like a measurement and would not be one.

A warm run reports `skippedBeforeOpening` and zero everywhere else. That is correct and is the point: an item the cache recognises is never copied out of the photo library and never hashed, so there is nothing else to count.

## Before: automatic import as it stands

Cold, hash cache deleted first, every photo exported and hashed:

```json
{"totalMs":66707,"childTaskMs":112944,"hashMs":27949,"cacheLookupMs":0,"filesHashed":24,"filesFromCache":0,"skippedBeforeOpening":0,"bytesHashed":49195872,"hashSharePercent":24.7,"hashMbPerSecond":1.68}
```

Warm, immediately after, over the same photos:

```json
{"totalMs":24182,"childTaskMs":0,"hashMs":0,"cacheLookupMs":0,"filesHashed":0,"filesFromCache":0,"skippedBeforeOpening":24,"bytesHashed":0,"hashSharePercent":0,"hashMbPerSecond":0}
```

| Measure | Cold | Warm |
| --- | --- | --- |
| Photos dealt with | 24 hashed | 24 recognised from the cache |
| Wall clock | 66.7 s | 24.2 s |
| Child task time | 112.9 s | 0 s |
| Hashing | 27.9 s | 0 s |
| Hashing's share of child task time | 24.7% | n/a |
| Megabytes hashed | 46.9 | 0 |
| Hashing rate | 1.68 MB/s | n/a |

## What the before figures say

**Hashing is 24.7% of a full import, against 99.1% of a bare scan.** The earlier scan measurement is not wrong; it measured a different thing. A scan lists, exports and hashes, and hashing dominates that completely. A full import also decodes each photo, makes a thumbnail and a display version, and writes to the database, and that work is three quarters of it.

**So the ceiling on this change is roughly a quarter, not the 45x the scan figures suggested.** Even if native hashing took the hashing to zero, a cold import of this library would go from 112.9 seconds of child task time to about 85, and the wall clock by something less than that, because the tasks overlap. Nothing about a faster hash touches the other 75%.

**The warm pass hashes nothing, so this change cannot help it at all.** 24.2 seconds of wall clock for 24 photos recognised without being opened, with no hashing and no child tasks. Whatever that time is, it is not hashing, and a faster hash leaves it exactly where it is.

**The hashing rate here is 1.68 MB/s, close to the 1.13 MB/s the earlier scan measured on an emulator** and about twice the phone's 0.75. That much is consistent, and it is the reason the phone run is still owed: the phone hashes at less than half this rate, so hashing will be a larger share of a full import there than the 24.7% measured here. How much larger is exactly what has not been established, and it is the number the decision turns on.

## After: automatic import with native hashing

Same emulator, same 24 photos, same time box, taken straight after the change landed.

Cold:

```json
{"totalMs":53833,"childTaskMs":88030,"hashMs":2403,"cacheLookupMs":1,"filesHashed":24,"filesFromCache":0,"skippedBeforeOpening":0,"bytesHashed":49195872,"hashSharePercent":2.7,"hashMbPerSecond":19.52}
```

Warm:

```json
{"totalMs":24178,"childTaskMs":0,"hashMs":0,"cacheLookupMs":0,"filesHashed":0,"filesFromCache":0,"skippedBeforeOpening":24,"bytesHashed":0,"hashSharePercent":0,"hashMbPerSecond":0}
```

## Before and after, side by side

Cold pass, the one this change is aimed at:

| Measure | Before | After | Change |
| --- | --- | --- | --- |
| **Wall clock** | **66.7 s** | **53.8 s** | **1.24x faster** |
| Child task time | 112.9 s | 88.0 s | 1.28x less |
| Hashing | 27.9 s | 2.4 s | **11.6x faster** |
| Hashing rate | 1.68 MB/s | 19.52 MB/s | 11.6x |
| Hashing's share of child task time | 24.7% | 2.7% | |
| Photos hashed | 24 | 24 | same |
| Megabytes hashed | 46.9 | 46.9 | same |

Warm pass, where nothing is hashed:

| Measure | Before | After | Change |
| --- | --- | --- | --- |
| Wall clock | 24.18 s | 24.18 s | unchanged |
| Photos recognised from the cache | 24 | 24 | same |

## What the comparison says

**Native hashing does exactly what it was expected to do: hashing is 11.6 times faster, and it is now 2.7% of the import instead of 24.7%.** That part is not in doubt and the figures are not marginal.

**The import as a whole got 1.24x faster.** That is the number a person waiting for their photos experiences, and it is what the decision is about. Hashing has gone from 27.9 seconds to 2.4, and the other 85 seconds of work, decoding each photo, making a thumbnail and a display version, and writing to the database, is untouched because none of it is hashing.

**The warm pass is unchanged, to within four milliseconds.** That was expected: a warm run hashes nothing, so there was nothing there for this change to make faster. It is recorded because a change that sped the cold pass up while slowing the warm one down would not be worth having, and this one does not.

**The cold pass was never going to gain more than about a quarter here, and it gained about a fifth.** The before figures said the ceiling was 24.7% and the change collected most of it. There is no version of this change that does better, because what is left is not hashing.

## The decision

**On the evidence available, this change does not clear the bar that was set for it, and the bar was set before the numbers were known.**

The rule agreed in advance was that the cold full import must be **at least several times faster on the phone**, and that hashing on its own getting hundreds of times faster would not save the change. Hashing got 11.6x faster. The import got 1.24x faster. That is a real improvement and it is not several times.

**The measurement is not yet the one the rule names.** These figures are from an emulator, because the Pixel 6 was not attached. The phone hashes at 0.75 MB/s against this emulator's 1.68, so hashing is a larger share of a full import there and the change is worth more on a phone than these figures show. How much more has not been measured and this document will not guess at it: the arithmetic that could be done here is exactly the kind of reasoning that produced the "45x" expectation the before run disproved.

What can be said without guessing:

- The part of the import that is not hashing is unaffected by this change, on any device.
- On this emulator that part is about 85 of 113 seconds of child task work.
- For the cold import to get several times faster, hashing would have to be most of it. On the phone it is a larger share than 24.7%, and whether it is large enough is the open question.

**So the phone run is what settles it, and it is the one thing this work has not been able to do.** The harness is in the tree and takes one command. Until it has been run, the honest position is that the change is measured, understood, and short of the bar on every measurement taken.

## Cost of keeping it, if it is kept

Worth weighing against the 1.24x, because it is not nothing and it is not much:

- A native function on each platform, both streaming, both pinned to the published SHA-256 vectors by unit tests.
- One `if` in the shared hashing path, choosing by whether the loaded crypto module exports a whole-file hasher, which is the mobile shim and nothing else.
- The correctness risk is the one that matters: these digests are the identity of every asset and the key of the hash cache. It is covered by unit tests on both native implementations against published vectors, by a test that the native and streaming paths agree byte for byte, and by the warm pass of this very measurement, which recognised all 24 photos from a cache the natively-hashed cold pass had written.

## The decision

Not yet reached. The test it has to pass is set out in the plan and repeated here so this document stands on its own: the cold full import must be **at least several times faster on the phone**, and the warm pass must not be slower. Hashing on its own getting hundreds of times faster is not the test and does not save the change.

Whichever way it goes, the figures stay in this document. A change that did not help is worth as much to the next person as one that did, provided the numbers are here to stop it being tried again on the same reasoning.
