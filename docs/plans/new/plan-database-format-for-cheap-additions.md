# Change the database format so adding files is cheap

## Overview

**The motivation is what the user sees.** During an import the app appears to do nothing at all, then the count jumps by 250 photos at once, then it appears to do nothing again. A photo is not in the gallery until the batch it belongs to is written to the database, and the batch is 250, so that is exactly what the app looks like from the outside: long dead periods punctuated by a lurch. It is doing the work the whole time, and none of it shows.

The batch is 250 because a commit is expensive and gets more expensive as the database grows. A commit rewrites every shard it touched, whole, and a shard holds every record that hashed into it, so adding a hundred records to a database of two thousand rewrites roughly forty per cent of the entire collection. Measured on a Pixel 6 during a real import, a commit grew from 5.4 seconds for the first batch to 60 seconds by the fifteenth, against a batch size that never changed. The sort indexes do the same thing again: a leaf page holds a full copy of every record in it and is rewritten whole whenever anything in that page changes.

So the batch size is the only defence available today, and it is a bad one: `DATABASE_BATCH_SIZE` in `packages/node-api/src/lib/import-assets.worker.ts` was raised from 100 to 250 to cut a full import from 55 minutes to 50, and that five minutes cost the user every sign that the app was working. Making the batch smaller again just trades the time back. The cost has to come out of the format instead, so that a small batch is affordable and progress is continuous.

This plan does not choose a format. It sets out the options to be explored, so the human can pick one, and only then does it implement. What any option is judged against: adding a record should cost something close to the size of that record, not something proportional to the size of the database, and the batch should then be small enough that photos appear steadily.

## Issues

## Steps

1. **Measure what a commit actually spends, per part, and write it down.** Extend `packages/bdb/perf-tests/run.ts` so each commit reports its time split between: BSON encoding of shard records, the storage write calls for shards, BSON encoding of sort index pages, and the storage write calls for index pages. Report bytes as well as milliseconds for each. Run it on the desktop across a growing collection (at least 25 batches of 250) and record the numbers in this plan under Notes. On device the same split is already partly known: of a 468 second write stage, only 35 seconds was inside the write calls, so roughly 92% was CPU in the engine building the bytes. Confirm the desktop figures agree on the ratio before designing anything around it. STOP when the numbers are recorded and wait for the human to read them: the option chosen in step 2 depends on which part actually dominates.

2. **Write up the options and let the human choose.** Create `docs/database-format-options.md` describing each option below: what changes on disk, roughly what an addition would then cost, what it costs to read, what it costs to sync and replicate, and how a database written by an older version is upgraded. No implementation. This document is what the human reads to make the choice. STOP when it is written and wait for the human to pick one. Revise the remaining steps of this plan to match what they pick before writing any code.

   The options to describe, all aimed at making an addition cost the size of the addition:

   - **Append to a shard rather than rewriting it.** A shard file becomes a sequence of records that can be added to at the end, so a commit appends the new records and leaves everything already there untouched. Needs a rule for when a shard is compacted, and a way to handle a record that is updated or deleted rather than added.
   - **Many more shards.** Raising `NUM_SHARDS` in `packages/bdb/src/lib/collection.ts` from 100 shrinks what each rewrite carries, because a shard holds fewer records. The cost is many more files and many more storage calls, which on mobile each cross the engine bridge. There is a number where those two curves cross, and step 1's measurements are what finds it.
   - **A journal in front of the shards.** New records are appended to one file per commit and folded into the shards later, in the background or when a read needs them. An addition then costs one small write. The cost is that every read has to consult the journal as well, and that the fold has to happen somewhere.
   - **Stop the sort index carrying a copy of every record.** `packages/bdb/src/lib/sort-index.ts` puts `fields: record.fields` in each leaf entry, so an index page is a second copy of the collection and is rewritten whole on any change. Holding only the sorted key and the record id would make a page a fraction of its current size. The cost is that reading a page of results then has to fetch those records.
   - **Smaller index pages.** `PAGE_SIZE` in `packages/bdb/src/lib/sort-index.ts` is 1000. Smaller pages rewrite less per change, at the cost of a deeper tree and more files.

   Note in the document which options combine: the index change is independent of the shard change, and either alone would help.

3. **Write the documentation for the chosen format.** Create or update the format documentation naming the on-disk layout as it will be after the change, the version number it is introduced at, and how an older database is read and upgraded. `packages/bdb/README.md` is where the format belongs. STOP when the draft is written and wait for the human to approve it. If they revise it, revise the remaining steps to match before continuing.

4. **Raise the database version and teach the reader both formats.** Increment `CURRENT_DATABASE_VERSION` in `packages/merkle-tree/src/lib/merkle-tree.ts`. Make the read paths in `packages/bdb/src/lib/shard.ts` and `packages/bdb/src/lib/sort-index.ts` recognise which format a file is in and read either, so a database written by the previous version still opens. The code must compile and all existing bdb tests must pass unchanged at this step: nothing writes the new format yet.

5. **Write the new format.** Change the commit path (`BsonShard.commit` in `packages/bdb/src/lib/shard.ts`, and the index page write in `packages/bdb/src/lib/sort-index.ts`) to write whichever parts the chosen option changes. Every new or changed function gets a unit test. The code must compile and all tests must pass.

6. **Add the upgrade.** Extend `apps/cli/src/cmd/upgrade.ts` so a database at the previous version is rewritten into the new format, following the pattern already there for the encryption upgrade. Unit test the conversion. The code must compile and all tests must pass.

7. **Prove the cost curve is flat.** Re-run the benchmark from step 1 and record the new per-commit cost against collection size in this plan. The check is that commit time stops growing with the number of records already stored, or grows far less. If it still grows, say so plainly rather than reporting the improvement alone.

8. **Lower `DATABASE_BATCH_SIZE` and measure on the device.** With commits cheap, reduce `DATABASE_BATCH_SIZE` in `packages/node-api/src/lib/import-assets.worker.ts` so that photos reach the gallery steadily rather than in lumps of 250. Run `apps/smoke-tests/tests/manual/90-perf-import/test.sh` against the physical Pixel 6, and record both the total import time and the batch size. The result must be no worse than the 45 minutes measured through the perf harness before this work, with a batch small enough that progress is visibly continuous.

9. **Update the documentation.** Revise `packages/bdb/README.md` and `docs/database-format-options.md` so they describe what was actually built, including anything that changed during implementation and any option that was tried and rejected.

## Unit Tests

- `packages/bdb/src/test/` gains a test per new or changed function in `shard.ts` and `sort-index.ts`: reading the old format, reading the new format, writing the new format, and the round trip of a record written and read back.
- A test that a shard which had one record added does not rewrite the records that were already in it, asserted through a counting storage like the one already in `packages/bdb/perf-tests/run.ts`.
- A test per new or changed function in the upgrade path in `apps/cli/src/cmd/upgrade.ts`, including a database already at the new version being left alone.
- Existing bdb tests must keep passing unchanged wherever the behaviour they describe has not changed. A test that has to be edited to pass is a behaviour change and must be called out as one.

## Smoke Tests

- `bun run test:cli` covers the CLI against a real database and must pass unchanged.
- `bun run test:cli:sync` and `bun run test:cli:write-lock` cover several processes reading and writing one database, which is where a format that appends rather than rewrites is most likely to go wrong.
- `bun run test:cli:encrypted` covers the same format under encryption.
- Add a CLI smoke test that creates a database with the previous version's format, runs `psi upgrade`, and verifies every record reads back and `psi verify` passes.
- `apps/smoke-tests/tests/manual/90-perf-import/test.sh` against the physical Pixel 6 is the measurement for step 8.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test:everything -- --force` passes.
- The benchmark from step 1, re-run, shows per-commit cost no longer growing with collection size.
- A database written by the previous version opens, reads correctly, and upgrades.
- A full import on the physical Pixel 6 finishes no slower than 45 minutes, with a batch size small enough that the gallery fills continuously.

## Notes

- **Every measurement that matters here is on the phone, not the desktop.** The desktop commits in tens of milliseconds and will not show the problem. The device is where a commit reached 60 seconds.
- **The cost is CPU, not disk.** Of a 468 second write stage measured on device, only 35 seconds was inside the write calls. The rest was the engine building the bytes: records are serialised to BSON in JavaScript, that JavaScript runs in QuickJS with no JIT, and the bytes then cross the native bridge as a base64 string. So an option that writes fewer bytes wins even if it makes more calls, and an option that makes many more small calls has to be measured rather than assumed.
- **The record size fix is already done and is not this.** Derivative images used to carry the original's metadata into every record, and fixing that took the database from 194 MB at 928 photos to 26 MB at 2,291. What remains is the growth curve, not the record size.
- **Why this is worth a format change at all:** it was reported as a user-visible fault, not found by profiling. The app looks like it is doing nothing between jumps of 250 photos. Any option that makes the commit cheaper but leaves the batch at 250 has not fixed the thing this plan exists for.
- **Open question for step 2:** whether to change the shards, the sort indexes, or both. They are independent and the sort index may be the cheaper win, since a leaf page currently holds a full copy of every record in it.
- **Constraint:** whatever is chosen has to survive several processes writing one database, which the write lock coordinates today, and has to replicate and sync unchanged. `bun run test:cli:sync` and `bun run test:cli:write-lock` are what prove it.
