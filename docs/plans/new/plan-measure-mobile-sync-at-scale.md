# Measure what prefetch, syncing and importing actually do at real scale

## Overview

Everything known about how a phone behaves against a database of thousands of photos is guesswork, and some of what has been said about it in this repository has turned out to be wrong: `docs/syncing.md` describes syncing as something that does not fill in a partial replica, while `sync.ts` copies thumbnails and root files into one; nobody knows how long a prefetch of eight thousand thumbnails takes, whether syncing waits for it, or whether the two are fetching the same files at the same time. This plan answers that with measurements rather than reading. It builds a private copy of the real database, serves it from a local MinIO, points a Pixel 6 at that copy as a partial replica, instruments the code, and records what happens and how long it takes. **The real bucket is read exactly once, to make the copy, and is never touched again, and the app is never connected to it.** Nothing is fixed: the deliverable is answers with evidence, and the two documents updated to hold what was learnt.

## Issues

## Steps

1. **Take the copy, and touch the real bucket for the last time.** Check free space first (the source is 33.9 GiB across 24260 files, and this machine had 254 GB free when the plan was written). Start a long-lived MinIO from `scripts/s3-emulator.sh start`, with its state directory under the repository's `tmp/`. MinIO serves each directory under `<state-dir>/data` as a bucket, so replicate straight into one and no second copy is needed: `psi replicate --db s3:photosphere-ash --dest <state-dir>/data/photosphere-ash-test`. Record how long the copy takes and how much it moved. Then verify the copy on its own terms with `psi verify --db <the local path>`, which reads only the copy. **From the end of this step, `s3:photosphere-ash` is out of bounds**: no CLI command names it, and nothing on the phone is configured with it.

2. **Make the copy reachable and registered.** Register the MinIO bucket in the CLI's database list with the MinIO credentials from the state directory's `env` file, so later commands resolve them by path. Confirm with `psi summary` against the `s3:` path (through MinIO, not the real bucket) that it reports the same photo count, file count and root hash the copy has. Those three numbers are the baseline every later measurement is compared against.

3. **Set the Pixel 6 up without wiping it.** Save its settings and keychain first, the way `apps/smoke-tests/tests/50-background-sync/test.sh` does (`android_save_sandbox_file` for `config.yaml` and `databases.toml`, `android_save_app_data_file` for the secure store), because `pm clear` must never run on a real phone. Then put in place: the MinIO S3 credentials, a database entry for the MinIO bucket, a partial replica of it in a test-named local database, an entry for that replica, that replica as the default database, and its origin set to the MinIO bucket. Seed these through the config files and the helpers in `apps/smoke-tests/lib/android.sh` rather than driving the interface: the setup flow is already covered by test 55, and this plan is about what happens afterwards. Assert, and keep asserting at every stage, that `databases.toml` on the phone contains no entry whose path is `s3:photosphere-ash`.

4. **Instrument what cannot otherwise be seen.** Add temporary logging, all of it under one distinctive prefix so `adb logcat` can be filtered to it, and all of it removed in the final step:
    - `packages/node-api/src/lib/prefetch-database.worker.ts`: when it starts, how many files it finds missing, each batch, bytes moved, when it ends.
    - `packages/node-api/src/lib/sync.ts` and `sync-database.worker.ts`: when a pass starts, what the early-out decides, how many files each direction moves and how many are skipped by the partial filter, when it ends.
    - `packages/node-api/src/lib/load-assets.worker.ts`: pages read, records per page, time to the first page and to the last.
    - `packages/mobile-worker/src/lib/plan-sync.worker.ts`: what each plan decides and the pause it returns.
    - `apps/android-frontend/.../SyncDriver.java` and `AutoImportService.java`: when a pass starts and ends, the pause asked for, the pause actually waited, and what woke it early. This is what answers why passes were seen ten seconds apart when the configuration says five minutes.
    Compile after this step. No unit tests: none of it survives to the end of the plan.

5. **Capture everything to a file.** Run `adb logcat` into `tmp/` for the whole of the measuring, filtered to the app's process, and keep the raw capture: every claim in the write-up has to be traceable to a line in it with a timestamp. Nothing in this plan may touch the phone's screen or foreground an app without saying so first.

6. **Measure the first open of the partial replica.** With syncing switched off in `config.yaml` and automatic import off, launch the app and open the replica. Record: time to the first records painted, time until the record count stops climbing, what the final count is and whether it reaches the origin's, when the prefetch task starts and ends, how many files it fetches and how many bytes. This is the measurement that answers what prefetch does and how long it takes.

7. **Measure syncing alone.** With the prefetch finished and automatic import still off, switch syncing on and let several passes run. Record what each pass moves in each direction, how long it takes, how long the gap between passes actually is, and whether the files it fetches are ones the prefetch already fetched. This answers whether syncing duplicates the prefetch.

8. **Measure them together.** Reset to a fresh partial replica (a second replica in a differently named local database, leaving the first in place for comparison), switch both on from the start, and record the interleaving: which tasks hold the three engine slots at each moment, whether a sync pass waits behind a prefetch, and whether both fetch the same file. This answers how the two relate and whether they contend.

9. **Measure importing at scale.** With about two thousand photos in the phone's library, switch automatic import on alongside syncing and let it run long enough to be representative. Record: how many photos are imported, how many are skipped as already present, how long a pass takes, how long a batch of 250 takes to commit, when the first push to the origin happens, and what the origin's file count does over time. This answers what stops background import and syncing working at this scale, and it is the measurement most likely to take hours rather than minutes.

10. **Write up the answers with their evidence.** Produce a new `docs/performance/mobile-sync-at-scale.md` holding the raw numbers, the log excerpts they came from, and the exact commands and device used. Then update the two documents the human asked for:
    - `docs/automatic-photo-backup.md`: what automatic import does at this scale, including deduplication against a database that already holds the phone's photos, which is the case that produced no imports at all on a real phone.
    - `docs/syncing.md`: correct the description of what a sync does to a partial replica (it copies thumbnails and root files into one, which the current text denies), state the relationship between syncing and the prefetch, and record the measured cost of a pass at this scale.
    Every claim in both must point at a measurement in the performance document. Where a measurement was not taken, say so rather than filling the gap.

11. **Throw the instrumentation away and put everything back.** Remove every line added in step 4 and confirm with `git diff` that nothing of it survives. Run `bun run compile`, `bun run test` and `bun run tev`. Restore the Pixel 6's saved settings and keychain, and say plainly in the write-up what has been left on the phone (the test replicas) and what remains on this machine (the MinIO data directory and its copy of the database), so the human can remove them when they choose.

## Unit Tests

None. This plan changes no production behaviour: the only code it writes is temporary instrumentation, which is removed in the final step, and the only lasting changes are documents. Adding tests for logging that is deleted before the plan ends would be writing tests for code that will not exist.

## Smoke Tests

None added. Test 55 already covers the joining flow at small scale, and the work here is measurement rather than behaviour that can be asserted in a runner. If a measurement turns out to be worth defending against regression, that is a separate plan written once the numbers exist.

## Verify

- `bun run compile` passes after the instrumentation is removed.
- `bun run test` passes.
- `bun run tev` passes, in one run.
- `git diff` shows no instrumentation left anywhere, and the only changes are the two documents and the new performance document.
- The phone's `databases.toml` never contained an entry for `s3:photosphere-ash`, evidenced by the captured logs and the file itself.
- Every number in the write-up can be traced to a line in the captured `logcat` or to a recorded command's output.

## Notes

- **The copy is the only contact with the real database, and it is a read.** `psi replicate` reads the source and writes the destination. Nothing in this plan writes to `s3:photosphere-ash`, and after step 1 nothing names it at all.
- **A full copy is needed, not a partial one.** The phone's replica is partial, but the origin it syncs against has to be a faithful copy of the real thing, including originals, or the measurements describe a database nobody has. That is 33.9 GiB of egress from the real bucket, once, and it is the cost of not risking the original.
- **MinIO serves directories as buckets**, so replicating into `<state-dir>/data/<name>` produces the bucket directly. The existing `scripts/s3-emulator.sh` starts the server and writes an `env` file with the port and credentials; it seeds its own bucket for the smoke tests, which is unrelated to the one this plan creates and can be left alone.
- **The phone is a real device with a real photo library.** Nothing here may run `pm clear`, and its settings and keychain are saved and restored. Everything this plan puts on it is named for the test.
- **Some of what is documented today is wrong**, which is the reason for the plan rather than a detail of it: `sync.ts` copies thumbnails and root files into a partial target, while `docs/syncing.md` says syncing does not fill in a partial replica. Whatever the measurements show, the documents end up saying what the code does.
- **No fixes.** Several of the things this plan will measure are already known to be wrong (passes ten seconds apart against a five minute setting; two mechanisms fetching the same thumbnails). Recording them precisely is the deliverable; changing them is a later plan, written against these numbers.
