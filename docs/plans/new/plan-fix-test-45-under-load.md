# Find and fix why test 45 loses the edit under load

## Overview

`apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh` passes when run on its own and fails when the whole Android suite runs in parallel. It fails at the point where it reads the encrypted S3 origin back with the CLI and finds no description, having already confirmed the edit is on the device's own disk and having seen the worker report a completed sync. The cause is not known. A clock-skew explanation was proposed and then undercut by reading `mergeValues` in `packages/bdb/src/lib/merge-records.ts`, which returns the defined side whenever the other side's value is `undefined`, before comparing timestamps at all. This plan is deliberately short: find where the description is actually lost, apply the smallest change that makes the test reliable, and stop. Replacing wall-clock ordering with vector clocks or hybrid logical clocks is a separate, larger piece of work already written up in `docs/plans/new/plan-clock-independent-merge.md` and is explicitly out of scope here.

## Issues

<empty>

## Steps

1. **Get a reliable reproduction before changing anything.** Run the Android suite with `bun run test:everything -- --force` (the pool must be up; check with `bun run emu:and:pool:status` at the moment of running, never from an earlier reading) and confirm test 45 fails while it passes from `apps/smoke-tests` via `PLATFORM=android bash ./run.sh 45`. Record how many of each it takes. If it cannot be reproduced, stop and report that rather than proceeding on the old evidence.

2. **Capture the worker's own account of the failing run.** The embedded worker logs to logcat, not to `app.log`, so `adb -s <serial> logcat -d` immediately after the failing run is the only place `Sync completed: N records merged`, `Databases are identical, no sync needed` and `Sync skipped ...` can be read. Identify which emulator ran the test from the runner output first. Record which of the two merge legs ran and how many records each reported.

3. **Establish whether the record ever reaches the origin at all, separately from whether it has the description.** Extend the failure branch of test 45's origin check to dump the whole record rather than the `psi info` summary: replicate the origin down as it already does, then read the record with `bdb record <dest>/.db/bson metadata <id> --all` (see `apps/cli/smoke-tests/lib/common.sh` `get_bdb_command` for how the CLI suites invoke it). This distinguishes "the field is absent" from "the field is present and empty" from "the record is an older version", which the current output cannot.

4. **Decide from steps 2 and 3 which leg loses it, and record the answer in this plan's Notes.** The candidates are: the push never ran; the push ran and the merge dropped the field; the pull ran first and removed the field from the replica before the push read it; or the origin holds it and the test's own read is wrong. Do not proceed until one of these is supported by evidence rather than by argument.

5. **Reproduce the losing merge as a unit test in `packages/bdb/src/test/`.** Once step 4 names the leg, drive `mergeRecords` in `packages/bdb/src/lib/merge-records.ts` directly with two records built to match what step 3 dumped, including the per-field metadata and the record-level timestamps. Watch it fail before accepting it. If `mergeRecords` cannot be made to lose the field, the fault is not in the merge and steps 6 and 7 do not apply.

6. **Apply the smallest change that fixes the cause found.** Scope this to one of: a fix in `mergeValues` / `mergeFields` / `cleanupMetadata` in `packages/bdb/src/lib/merge-records.ts`; a fix in the push leg of `syncDatabases` in `packages/node-api/src/lib/sync.ts`; or a fix in the test if the fault turns out to be the test's read. Nothing broader. If the only correct fix is a new ordering scheme, stop and say so rather than starting it here.

7. **Make the test's origin read non-racy regardless of the outcome above.** The current check reads the bucket once, immediately after the frontend logs `Sync completed: changes synced`, and that message is emitted when the task message arrives rather than when the worker has finished writing. Replace the single read with a bounded poll that retries the replicate-and-read, so a slow write cannot be reported as a missing one. This is correct on its own merits and should land whether or not it is the cause.

8. **Remove the root-hash inference from test 45.** The failure branch currently prints "syncDatabase took an early return" based on the origin's root hash being unchanged, which is a conclusion the comparison cannot support: `psi root-hash` was never checked to be sensitive to a metadata-only change. Either verify that it is and keep the message, or delete the claim. A diagnostic that states an unproven cause is worse than one that states only what it measured.

9. **Prove the fix by repetition, not by one pass.** Run the full `bun run test:everything -- --force` three times and confirm test 45 passes in all three. A single green run of a test that was previously load-sensitive proves nothing, and treating one pass as proof is what let this reach the main branch.

## Unit Tests

- `mergeRecords` in `packages/bdb/src/lib/merge-records.ts`: the case reproduced in step 5, watched failing before the fix and passing after. This is the test that pins the actual defect.
- `mergeValues`: a field present on one side and absent on the other, asserting the present value wins regardless of either timestamp. This encodes the behaviour the code appears to have and that the failure appeared to contradict, so it is worth holding still.
- `cleanupMetadata`: a field whose metadata survives a merge is not dropped when the record-level timestamp is older than the field's.
- If step 6 changes `syncDatabases`, a test in `packages/node-api/src/test/lib/` covering the push leg specifically.

## Smoke Tests

- `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh` is the behaviour under test and must pass under the full parallel suite, not only standalone.
- Extend `packages/node-api/src/test/lib/sync-metadata-edit.test.ts`, which already drives create → replicate → edit → sync entirely on the host, with whatever case step 4 identifies. It runs in seconds and needs no device, so any case it can hold belongs there rather than in a three-minute emulator test.
- `apps/cli/smoke-tests/37-sync-edit-field` and the other CLI sync suites must keep passing unchanged.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including the new bdb tests.
- `bun run test:everything -- --force` passes three times in a row, with the emulator pool checked immediately before each run.

## Notes

- Evidence already gathered, none of it conclusive on its own: the edit reaches the device's disk (test 45 asserts this and it passes); the worker logs `Sync completed: 1 records merged.` twice, once per leg; the origin ends up without the description; the emulator clock is 26 seconds behind the host, measured twice.
- The clock-skew theory is doubtful, not dead. `mergeValues` returns the other side when one value is `undefined`, before any timestamp comparison, so an absent field on the origin should not have lost to a lower timestamp. It could still be live if the field is not absent but deleted-with-metadata, which is what step 3 is for.
- The failure appears under parallel load and not standalone, which is the opposite of the usual pattern. The working theory for that is that load shortens the elapsed time between the host writing the origin and the device making the edit; whether that matters depends entirely on step 4.
- Test 45 needs the LAN bridge and is skipped in CI, so this can only be reproduced locally. That also means the failure never blocked CI and is not urgent for the pipeline, only for trusting the test.
- `docs/plans/new/plan-clock-independent-merge.md` covers the long-term fix. If step 6 concludes that only a new ordering scheme is correct, that plan is where the work goes, and this one should end with that finding recorded.
