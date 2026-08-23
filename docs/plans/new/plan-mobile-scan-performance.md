# Measure the automatic import scan on a real device, cold cache and warm

## Overview

We do not know how fast automatic import reads a real photo library, nor what the hash cache is worth in practice. This plan measures both on a physical Android device holding roughly 2,000 photos: one run with the hash cache deleted, so every item is exported from the library and hashed, and a second run straight after it, where every item is answered from the cache. It reports items per second, megabytes per second, and the ratio between the two runs. Nothing is imported: no database is written, no thumbnails or display versions are generated, and no photo on the device is touched. The measuring code is written in a throwaway worktree and discarded afterwards; the only thing kept is a results document.

## Issues

## Steps

1. **Create the worktree.** Run `git branch --show-current` to get the current branch, then `git worktree add -b perf-scan-measure .claude/worktrees/perf-scan-measure <current-branch>`, then enter it with `EnterWorktree` using the `path` parameter. Every step below happens inside that worktree. Nothing from it is merged except the results document, which step 12 copies out.

2. **Add the throwaway measuring task to the mobile worker.** Create `packages/mobile-worker/src/lib/perf-scan.worker.ts` exporting `perfScanHandler(data: IPerfScanData, context: ITaskContext): Promise<IPerfScanResult>`. It must reuse the real pieces rather than reimplementing them: `DeviceMediaSource` from `packages/mobile-worker/src/lib/device-media-source.ts` for the listing and the export, `HashCache` and `getHashCacheDir` from `packages/node-api/src/lib/hash-cache.ts`, and `getHashFromCache` / `validateAndHash` from `packages/node-api/src/lib/hash.ts`. For each item, in this order: ask the cache using the item's `IFileCacheIdentity` (source id, size, created time); on a hit, count it and move on without opening the item; on a miss, `openItem`, `validateAndHash` the exported copy, add the hash to the cache under `addSourceHash`, then `closeItem`. Save the cache every 100 entries, as the import does, and once at the end. Never write to a database, never queue an upload, never generate a derivative.

   `IPerfScanData` carries only `pageSize: number`. `IPerfScanResult` carries: `itemsSeen`, `cacheHits`, `cacheMisses`, `bytesHashed`, `failures`, and four elapsed millisecond totals measured with `context.timestampProvider.dateNow()` around each part: `listingMs`, `exportMs`, `hashMs`, `cacheLookupMs`, plus `totalMs` for the whole run.

3. **Register the task.** In `packages/mobile-worker/mobile-worker-entry.ts`, add `registerHandler("perf-scan", perfScanHandler)` beside the existing registrations.

4. **Add the throwaway trigger.** In `packages/user-interface/src/lib/test-driver.ts`, add a `case 'perf-scan':` beside the existing commands that queues the `perf-scan` task through the platform's queue backend, awaits it, and writes the result to the app log as a single line beginning `PERF-SCAN-RESULT ` followed by the result object as JSON. This is test-only scaffolding in app code and exists solely because this worktree is discarded.

5. **Write the summarising function, with unit tests.** Create `packages/node-api/src/lib/perf-scan-summary.ts` exporting `summarisePerfScan(cold: IPerfScanResult, warm: IPerfScanResult): string`, a pure function returning the markdown table body: items per second and megabytes per second for each run, the cold-to-warm ratio, and the per-stage split as a percentage of each run's total. It must divide by zero safely (a run that saw no items reports zero rather than `NaN`). Unit tests go in `packages/node-api/src/test/lib/perf-scan-summary.test.ts` per the Unit Tests section. This is the one piece of the throwaway code that gets tests, because it does arithmetic that a wrong number would silently pass through into the results document.

6. **Add the smoke test that drives both runs.** Create `apps/smoke-tests/tests/90-perf-scan/test.sh`, following the layout of `apps/smoke-tests/tests/47-auto-import/test.sh` (source `../../lib/common.sh`, `print_test_header 90 "perf-scan"`, exit trap that stops the app). It must:
   - Refuse to run on any platform but Android, the same way test 47 does.
   - **Never call `android_remove_media`, `android_remove_media_matching` or `android_seed_media`.** This runs against the human's own photo library. The test reads; it must not add or delete a single photo. Add a comment saying so.
   - Grant the media permission with `android_grant_media_permission`.
   - Start the app and wait for ready.
   - Delete only the hash cache before the cold run: `adb shell run-as "$APP_ID" rm -rf files/tmp/photosphere/hash-cache`. Do not use `android_reset_app_state`, which would wipe the databases and settings as well.
   - Send `perf-scan`, then wait for a `PERF-SCAN-RESULT` line in the app log, allowing at least 3600 seconds: two thousand photos exported and hashed on a phone is not a fast thing.
   - Send `perf-scan` a second time without deleting anything, and wait for the second `PERF-SCAN-RESULT` line.
   - Fail loudly if the second run's `cacheHits` is not equal to its `itemsSeen`, because a warm run that missed the cache measures nothing this plan set out to measure.
   - Write both JSON lines to `$TMP_DIR/perf-scan-results.json` so step 11 can read them.

7. **Keep it out of the normal test runs.** Do not add the new test to `apps/smoke-tests/run.sh`'s default set if that file enumerates tests; check with `grep -rn "47-auto-import" apps/smoke-tests` and, if the list is explicit, leave 90 out of it. The test is invoked directly by number in step 10. Confirm `bun run test:everything -- --plan` does not mention it.

8. **Compile and unit test.** Run `mise exec -- bun run compile` and `mise exec -- bun run test`. Both must be clean before anything is run on the device.

9. **Pin the run to the human's device.** Run `adb devices -l` to find its serial. The device is not a pool emulator, so the run must be pinned with `PHOTOSPHERE_ANDROID_DEVICES="<serial>"`. Do not start, stop, repair or otherwise touch the emulator pool for this work.

10. **Run it.** `PHOTOSPHERE_ANDROID_DEVICES="<serial>" mise exec -- bun run test:and -- 90-perf-scan`. If it fails part way, read `/tmp/photosphere-tests/perf-scan-*/test-run.log` and the app log beside it, fix, and run again. Record how long the whole thing took.

11. **Write the results document.** Create `docs/performance/mobile-auto-import-scan.md` holding: the device model, Android version and photo count; the date; the two raw result objects; the table from `summarisePerfScan`; and a short section in prose saying what the numbers mean, including the answer to the three questions this was run for (how long each run took, how many files per second each managed, and how much faster the warm run was). State plainly what is measured and what is not: the export of each item out of the photo library happens on both runs and is not saved by the cache, and no thumbnail, display version, database write or upload is included in either number.

12. **Keep the document, discard the code.** Copy `docs/performance/mobile-auto-import-scan.md` out of the worktree into the main working copy. Then leave the worktree: `ExitWorktree`. Do not merge the branch. Tell the human the worktree and branch still exist so they can delete them.

## Unit Tests

- `packages/node-api/src/test/lib/perf-scan-summary.test.ts`, covering `summarisePerfScan`:
  - Reports items per second and megabytes per second for a run with known totals and elapsed time.
  - Reports the cold-to-warm ratio for two runs with known totals.
  - Returns zeros rather than `NaN` when a run saw no items, and when a run's elapsed time is zero.
  - Splits the per-stage percentages so they sum to one hundred for a run whose stage totals sum to its total.

No unit tests for `perfScanHandler` itself: it is throwaway code whose only job is to drive the real `DeviceMediaSource`, `HashCache` and hashing functions, all of which have tests of their own, and it is proven by producing the measurement. The test driver command is a shell over the queue and is covered by the smoke test.

## Smoke Tests

- `apps/smoke-tests/tests/90-perf-scan/test.sh`, as described in step 6. It is the whole measurement, and it also asserts the two things that make the measurement meaningful: the cold run's `cacheMisses` equals its `itemsSeen`, and the warm run's `cacheHits` equals its `itemsSeen`.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes, including the new `perf-scan-summary` tests.
- `mise exec -- bun run test:everything -- --plan` does not list the new perf test, so the normal test runs are unaffected.
- `PHOTOSPHERE_ANDROID_DEVICES="<serial>" mise exec -- bun run test:and -- 90-perf-scan` passes on the device, and `/tmp/photosphere-tests/perf-scan-*/perf-scan-results.json` holds two result objects.
- The warm run's `cacheHits` equals its `itemsSeen`, and the cold run's `cacheMisses` equals its `itemsSeen`. Without both, the two runs are not the two runs this was for.
- `docs/performance/mobile-auto-import-scan.md` exists in the main working copy and holds real numbers, not placeholders.

## Notes

- **Why not `dryRun`.** The import task already takes a `dryRun` flag, and it would be the obvious way to scan without importing. It is the wrong instrument here: `upload-asset.worker.ts` only skips the *writes* under `dryRun`, and still generates the thumbnail and the display version first. A dry run would therefore measure ImageMagick rather than the scan, and on a phone that is the dominant cost. The throwaway task exists to stop at the hash.
- **What the warm run actually saves.** The cache is consulted before the item is opened, and a hit avoids exporting the photo out of the library as well as hashing it, which is why the identity is the source id, size and created time rather than a file path. So the warm run measures listing plus a cache lookup per item. This is the same path automatic import takes for a photo it has already taken in, so the ratio is the real one.
- **Why not measure through automatic import itself.** It would need a database to write into, which means importing the human's 2,000 photos, which he has asked not to happen.
- **The hash cache path on the device.** `getHashCacheDir` puts the cache under `getProcessTmpDir()`, and the mobile `os` shim returns the sandbox-relative `tmp`, so on Android it lands under the app's `files/tmp/photosphere/hash-cache/<database key>`. The key is derived from the database path, so the throwaway task must use the same database path string both runs or the warm run will look in a different directory and miss everything. The smoke test's check on `cacheHits` is what catches that mistake.
- **This is test-only scaffolding in app code**, which the repository normally forbids without asking first. It is allowed here because the human asked for the measurement to be built in a worktree and thrown away, and nothing from it is merged.
- **The device is not a pool emulator.** Everything about the emulator pool stays untouched: no `emu:and:*` commands, no repairs, no sudo.
