# Get a 2,187 photo import on a phone under two hours

## Overview

A full automatic import of the Pixel 6's own library takes about 4.5 hours with native hashing in place, measured at 9.7 seconds per item over a 31 item sample. The target is under two hours for the whole library, which is 3.29 seconds per item, so this has to find a little under a 3x improvement.

Hashing is already dealt with and is not the target here: it is under 2% of a real import on that phone. Everything else is unmeasured. So this plan does not begin by choosing what to optimise. It begins by measuring every stage of the import on the device, ordering them into a leaderboard by how many seconds each contributes across the whole library, and then working down that leaderboard one entry at a time.

**Every measurement in this plan is taken on the physical Pixel 6. None is taken on an emulator.** The emulator has already misled this work once: it reported hashing at 24.7% of an import where the phone reports under 2%, because the emulator library was seeded photos with no videos and the phone's is real. An emulator figure is not evidence for anything here.

## Issues

## Steps

1. **Break the import's timings down by stage.** `IImportTimings` in `packages/api/src/lib/import-assets.types.ts` currently separates hashing from everything else. Add a field per stage: `exportMs`, `metadataMs`, `microMs`, `thumbnailMs`, `displayMs`, `uploadMs`, `databaseWriteMs`, and keep the existing `hashMs`. Time each stage where it happens: the derivative and upload stages in `uploadAssetHandler` (`packages/node-api/src/lib/upload-asset.worker.ts`), returned on `IUploadAssetResult`; the export in `AutoImportScanner.pushItem` (`packages/node-api/src/lib/auto-import-scanner.ts`) around `deps.source.openItem`, carried through to the import; the database write in `processPendingDatabaseUpdates` (`packages/node-api/src/lib/import-assets.worker.ts`). Extend `addUploadAssetTiming` and `formatImportTimings` in `packages/node-api/src/lib/import-timings.ts` to fold them in and report them. Also report the item counts each stage applied to, and count photos and videos separately, because a stage that is slow only for videos is a different problem from one that is slow for everything.

2. **Take the baseline on the device, twice.** Run `90-perf-import` against the Pixel 6 twice, back to back, with no code change between them. Two runs, not one, because nothing later in this plan can call an improvement significant without knowing how much two identical runs differ. Record both, and record the difference between them as the run-to-run variation every later comparison is judged against.

3. **Build the leaderboard.** Create `docs/performance/mobile-import-leaderboard.md`. For each stage, record the measured milliseconds per item, the projected total across 2,187 items, and that total as a percentage of the projected full-library time. Order it by projected total, largest first. Add a status column, every entry starting as "not attempted". This file is the plan's working state from here on: it is updated after every attempt, kept in the repository, and committed with the change it describes.

4. **Work down the leaderboard, one entry at a time.** For the topmost entry not yet marked done or abandoned:

   a. **Choose an approach** for that stage and write it into the leaderboard entry before implementing it, so an approach that fails is on record and is not tried twice.

   b. **Implement it**, with unit tests for every new or changed function, and confirm `mise exec -- bun run compile` is clean and the affected unit tests pass.

   c. **Measure it on the device** with `90-perf-import`, the same way and for the same time box as the baseline.

   d. **Judge it.** The change is kept only when the projected full-library time falls by **at least 10 minutes** and by **more than the run-to-run variation recorded in step 2**. A change inside the noise has not been shown to do anything, whatever the stage timing says.

   e. **If it passes**, update the leaderboard with the new figures, mark the entry done, and **commit that change on its own**, with the leaderboard update in the same commit. One improvement per commit, so any of them can be reverted alone if it turns out to cost something elsewhere.

   f. **If it fails**, revert the attempt, record in the leaderboard entry what was tried and what it measured, and go back to (a) with a different approach. **After three failed attempts on one entry, mark it abandoned, record all three results, and move to the next entry.**

   g. **Stop early** the moment the projected full-library time goes under two hours. The remaining entries stay in the leaderboard as unattempted, which is the record of what is left if the target moves.

5. **Record the outcome.** Update `docs/performance/mobile-import-leaderboard.md` with the final projected time, and state plainly whether 2,187 photos now import in under two hours. If they do not, say how far it got, which entries were abandoned and why, and what the remaining time is spent on.

## Unit Tests

- `addUploadAssetTiming` and `formatImportTimings` in `packages/node-api/src/lib/import-timings.ts`: every new per-stage field accumulates and is reported, photo and video counts are kept apart, and folding one result in leaves the totals it was given untouched. Extend `packages/node-api/src/test/lib/import-timings.test.ts`.
- Every function changed by an attempt in step 4 gets a unit test as part of that attempt, before it is measured. An attempt that is reverted takes its tests with it.
- Where an attempt adds a native host function, it gets a JVM test under `apps/android-frontend/android/app/src/test/.../` and a matching XCTest in `apps/ios-frontend/ios/App/AppTests/`, both pinned to a known input and its expected output, plus the missing-file and outside-the-sandbox cases.
- Where an attempt adds a choice between a native path and a portable one, the chooser is tested both ways, with the native side passed in as an argument rather than looked up, following `computeFileHash` in `packages/node-api/src/lib/hash.ts`. A path that cannot be reached from a test is a path that ships unrun.

## Smoke Tests

- `apps/smoke-tests/tests/47-auto-import/test.sh` must keep passing unchanged after every attempt. It imports real photos through the real path, so a derivative that comes out wrong or an import that stops working shows up there.
- `apps/smoke-tests/tests/21-import-video/test.sh` must keep passing after every attempt, which is what covers the video path.
- Add an assertion to the import smoke tests that the micro, thumbnail and display images are all present and non-empty for an imported photo, so an attempt cannot silently drop one of the three and look faster for it.
- `apps/smoke-tests/tests/manual/90-perf-import/test.sh` is the measurement. It is run by name against the phone and is never part of an ordinary run.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test:everything` passes before each commit. It needs the Android emulator pool up.
- `mise exec -- bun run test:and:unit` passes, covering any new Android host function.
- Every kept change has its own commit, and each of those commits contains the leaderboard update that justifies it.
- `docs/performance/mobile-import-leaderboard.md` records, for every entry attempted: what was tried, what it measured, and whether it was kept, including the three results behind any abandoned entry.
- Every figure in the leaderboard was taken on the physical Pixel 6. No emulator figure appears in it.

## Notes

**Where the time goes, as far as it is known today.** On the Pixel 6, with native hashing in place: 31 items, 143.5 MB, 300 seconds of wall clock, 378 seconds of child task time, of which hashing was 5.3 seconds. So the great majority of the per-item cost is something other than hashing, and which part is unknown. That is what step 1 exists to answer, and no optimisation should be attempted before it does.

**Candidate approaches, for step 4a to draw on.** These are researched but unproven, and none should be implemented before the leaderboard says its stage is worth attacking.

- `generateImageAssets` in `packages/node-api/src/lib/image.ts` calls `resizeImage` three times, once each for micro, thumbnail and display, and each call decodes the full-size original again. One pass writing three outputs would remove two decodes per photo. `Image.resize` in `packages/mobile-worker/src/shims/mobile-tools.ts` builds the argv, so this changes an invocation count and adds no dependency.
- A video thumbnail costs about ten seconds of ffmpeg. Android's `MediaMetadataRetriever.getFrameAtTime` and iOS's `AVAssetImageGenerator` do the same job with the platform's own decoder, reached through a host function beside the `sha256` one.
- `MOBILE_MAX_CONCURRENT_CHILD_TASKS` in `packages/mobile-worker/src/lib/mobile-worker-runtime.ts` is 2, chosen so an import cannot make the interface wait. An import running under `AutoImportService` with the app off screen has no interface to protect.
- Effective concurrency measured 1.28 against a limit of 2, so something already serialises the child tasks. Worth understanding before raising any limit: the write lock taken per batch in `processPendingDatabaseUpdates`, the asset server engine held for the life of the app, and the orchestrator task occupying an engine while it waits.

**Do not reimplement ffmpeg or ImageMagick.** Calling a platform API that already does the job is fine and is what the native hash did. Hand-writing a decoder, a container parser or anything else a maintained library already does is out of scope and needs asking about first.

**The measurement needs a physical phone and three things set on it.** `PHOTOSPHERE_NO_LAN_BRIDGE=1` on the run, Developer options' "Verify apps over USB" turned off so Play Protect does not hold each install for a tap, and a device-idle temporary allowlist entry so the app can start its foreground service from behind a lockscreen. `90-perf-import` asks for the allowlist entry itself.

**A cold pass has to run long enough to flush the hash cache**, which happens every hundred files. A shorter pass leaves the cache empty, and the warm pass that follows then measures nothing. At the rate measured so far that means a box of about fifteen minutes.

## Result: under two hours, measured on the Pixel 6

A full import of the phone's library, 2,291 items of 2,307, now takes **45 minutes**. The target was under two hours. Before this session's work no run had ever finished at all: every one died at the same photo, 39 files in.

Every figure below is wall clock on the physical Pixel 6, counting files in the app's own `asset/` directory on the device rather than reading the harness's timing log, because that log stops arriving part way through a long run.

Progression of a full import through the perf harness: never finished -> 55 min -> 50 min -> 45 min, confirmed at 45 again on the final committed code. Switched on by hand on the phone, the same library came in in 25 minutes: see the note on the pacing below.

### The commits, and what each was worth

| Commit | What it does | Measured effect |
| --- | --- | --- |
| `61b39a48` Stopped a WebP taking the whole app down mid-import | The bundled Android ImageMagick null-derefs in `WebPDecode` on any WebP carrying alpha, and it runs in-process so its crash is the app's. Android's own decoder converts a WebP to PNG and ImageMagick reads that. | Every import used to die at 39 files. This is what made a full import possible at all. |
| `3e6cddf4` Read the hash cache once per engine, not once per photo | `hash-file` built a fresh `HashCache` and re-read the whole file per photo, so the cost grew with the cache. Held per directory now, re-read only when the file's length or modified time changes. | Cache loading 105.8s at 800 photos -> 2.5s at 596, and flat instead of growing. |
| `ad9ba680` Stopped giving every late photo a database commit of its own | The "scanner is caught up, write what is waiting" escape fired while hundreds of photos were still in flight, so each got a full commit. It now also requires nothing in flight. | Removed the wall at ~1,800 photos where the rate fell from 60/min to 4.5/min. First run ever to finish: 55 min. |
| `2366ef01` Wrote the database in batches of 250, not a hundred | A commit rewrites every shard it touches, so fewer commits is the lever. 250 had been rejected before on a misdiagnosis that this session disproved. | 55 min -> 50 min. Database time at the same point in the run 47.0s -> 29.6s. |
| `defa3a66` Took a photo's size from the EXIF already read, not a second read | The EXIF parse walks the JPEG markers and the frame header gives width and height, which was thrown away and asked of ImageMagick separately. Non-JPEG still asks the tool. | Probe stage 166ms -> 28ms a photo. 50 min -> 45 min. |
| `14017f28` Stripped derivatives properly, because +profile xmp does nothing on Android | `+profile xmp` silently fails on the bundled Android ImageMagick, so every derivative kept the original's metadata. Only `-strip` works. | Thumbnail 116 KB -> ~1.4 KB in the record. Database 194 MB at 928 photos -> 26 MB at 2,291. Database write time 958s -> 30s. |
| `eb576f09` Made the LAN share suite follow the app when it is relaunched | Not a performance change. `READY-RELAUNCH-STALE-PORT` recurred in a suite the recorded fix never covered, and blocked a commit. | None. Registry entry unticked and the recurrence recorded. |

### What was tried and thrown away

Each of these was written, and then discarded because no measurement showed it helped. They are listed so nobody spends the time again without a reason to.

- **Bringing ImageMagick's library state up once per process** instead of `MagickWandGenesis`/`MagickWandTerminus` around every invocation. Written to fix the crash at 39 files; the crash was WebP and this changed nothing about it. It is what the library documents, so it may still be worth doing, but it was never measured on its own.
- **Refunding the pacing token when an item is recognised as already imported.** Written on the theory that a second walk crawled because skips cost budget. The wall at 1,800 survived it, so the theory was wrong, and no run attributed anything to it.
- **Naming an exported library item by its MIME type rather than its display name.** Written chasing the crash on a Motion Photo named `.MP`, which was not the cause either.
Note that `-strip` was thrown away too, and putting it back is the `14017f28` commit above. It had been introduced to dodge the crash, the crash turned out to be WebP, so the reason written on it evaporated and it was reverted for costing every derivative its colour profile. The next run showed what that reasoning missed: the flag was doing a second job nobody had written down, because the `+profile xmp` it replaced does nothing at all on this build. A change whose stated reason is wrong is not the same as a change that does nothing, and the way to tell them apart is to measure rather than to reason about the comment.

### The ceiling ahead

`backfill_items_per_minute` defaults to 60, so the **backfill** lane releases at most one photo a second, and every measurement in this plan was taken through that lane, which is why they sit near 45 minutes.

That is not the floor for a real first import. Switching automatic import on by hand and letting the library arrive took **25 minutes for the same 2,291 items**, running at 73 a minute, because the fast lane carries what the watcher reports and is not paced at all. So the pacing bounds a backfill of a library the app has already walked past, not a phone taking in its photos for the first time.

Worth knowing before optimising further: a measurement taken through the perf harness is paced and a real first import is not, so the harness understates what a user sees, and the remaining per-photo cost matters more than the 45 minute figure suggests.

Where the remaining per-photo time goes, measured at 613 files: ImageMagick is about 80% of the child work, and the largest parts are the display resize (~324ms), the EXIF read (~303ms), the hash (~171ms) and the thumbnail resize (~146ms). The three resizes already chain off each other rather than each decoding the original.

### Measuring this again

The perf harness reports FAIL on a good run, because it reads timings from a log delivered over a WebSocket from the app and that connection dies about 40 minutes in. Count files on the device instead:

```
adb -s <serial> shell "run-as au.com.codecapers.photosphere ls files/photosphere-default/asset | wc -l"
```

Poll that every five minutes against a `90-perf-import` run and watch for the count to stop rising.

## The database format is unchanged

**No change was made to the database format.** Checked three ways:

- No commit in this work touches `packages/bdb` (the database engine), the asset record type in `packages/api`, or `upload-asset.worker.ts` / `media-file-database.ts`, which are what build a record. `git diff --stat` over the whole range returns nothing for any of them.
- The one change that goes anywhere near a record is where a photo's width and height come from: the EXIF read the import had already done, rather than a second read by an image tool. It writes the same two fields it always wrote. The `dimensions` the EXIF read now returns is destructured out before the rest is spread into the asset details, so it cannot reach a record.
- Read back from the imported database on the device, the fields present across all 2,291 records are exactly: `_id, color, contentType, description, duration, fileDate, hash, height, labels, micro, origFileName, origPath, photoDate, properties, uploadDate, width`. No field added, none missing.

One field's **contents** got smaller, which is not a format change and is the point of the `-strip` commit: the `micro` thumbnail inside each record now averages 1,370 bytes instead of carrying tens of kilobytes of the original photo's metadata.

## Verified: the import really did the work

Checked after a full import on the Pixel 6, because a faster import that quietly skips work is worse than a slow one.

**Every item on the device is accounted for.** The library holds 2,307 items (2,187 images, 120 videos, counted from MediaStore).

| | Count |
| --- | --- |
| Imported as assets | 2,291 |
| Duplicates: content already stored under another library item | 14 |
| Failed, and reported as failed | 2 |
| **Total** | **2,307** |

The 14 duplicates are the import doing its job: each was hashed, its content found already in the database, and no second copy stored. Confirmed by cross-referencing the hash cache against the database: every one of their hashes is present under another asset. All 2,291 stored hashes are distinct.

The 2 failures are both files nothing could have imported, and both were counted as failures rather than silently dropped:

- `1728013234744.gif`, an **animated** GIF. A resize of one writes a file per frame (`out-0.jpg`, `out-1.jpg`, ...), so the single output path the import expects never exists. Pre-existing: reproduced on the device with the bundled ImageMagick under both the old flags and the new, with identical results.
- `received_376344457763121.mp4`, 794 bytes. Not a playable video.

**The derivatives are real.** 2,291 assets, 2,291 thumbnails, 2,172 display images, no zero-length file anywhere. The 119 without a display are the videos: `video.ts` makes a thumbnail and a micro for a video and no display, by design, and that file was not touched. Twelve thumbnails and twelve display images sampled at random and decoded: every one a valid JPEG, thumbnails at the 300px minimum and displays at the 1000px minimum, aspect ratios preserved.

**The records are complete.** All 2,291 have a hash, a content type, a width and height greater than zero, a photo date and a micro image. Content types: 1,981 JPEG, 176 PNG, 119 MP4, 11 WebP, 4 HEIC.

**Sizes are sane.** Database 26 MB, originals 7.8 GB, display images 994 MB, thumbnails 94 MB.
