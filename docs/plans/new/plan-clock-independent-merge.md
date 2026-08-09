# Clock-independent record merging

## Overview

Sync merges records field by field and resolves conflicts by comparing wall-clock timestamps taken from whichever machine made each write (`mergeValues` in `packages/bdb/src/lib/merge-records.ts`). Those clocks are not the same clock. A phone 26 seconds behind the desktop that wrote the origin can make an edit *after* that write and have it stamped *before* it, so the edit loses a merge it should win, silently and with no error anywhere. Nothing in the design bounds that skew, so the failure is not a bug to be found and removed but a property of using wall time as the ordering. This plan replaces the ordering with one that does not depend on clocks agreeing: either vector clocks or hybrid logical clocks. Both options are written up here; the choice is deliberately left open.

## Issues

- [ ] The root cause is NOT proven. See the first note below: reading `mergeValues` suggests a defined value already beats an absent one regardless of timestamp, which contradicts the clock-skew story that motivated this plan. Step 1 exists to settle that before anything is built. If step 1 shows clock skew cannot produce the observed loss, this plan should be reconsidered rather than continued.

## Steps

1. **Prove or disprove the clock-skew failure before changing anything.** Add unit tests to `packages/bdb/src/test/` driving `mergeRecords` directly with two records whose per-field and record-level timestamps are set by hand: (a) target record written later than the incoming field, incoming field present, target field absent; (b) both fields present, incoming newer in real time but older by timestamp; (c) the same with per-field metadata absent so the record-level timestamp is the fallback. Record in this plan's Notes which cases actually lose the incoming value. Do not proceed to a design until one of them reproduces the loss.

2. **Decide between Option A and Option B below and record the choice in the Notes.** Everything after this step depends on the answer, so the remaining steps are written once and refer to "the chosen ordering".

3. **Introduce the ordering type in `packages/bdb/src/lib/`.** A new module exporting the ordering value type, a `compare` function returning less-than / greater-than / concurrent, and a function to advance it for a local write. Keep it free of storage and I/O so it is directly unit-testable.

4. **Carry the ordering in record metadata.** Extend `Metadata` in `packages/bdb/src/lib/collection.ts` and `IInternalRecord` in `packages/bdb/src/lib/shard.ts` so each field can hold the ordering value alongside (not instead of) the existing `timestamp`. Keeping the timestamp is deliberate: it stays useful for display and for reading old data, and nothing has to migrate on read.

5. **Set the ordering on write.** `updateOne` and the other write paths in `packages/bdb/src/lib/collection.ts` currently stamp `timestampProvider.now()`; they must also advance and store the ordering value. This is where the device identity (Option A) or the counter (Option B) enters.

6. **Compare on the ordering in `mergeValues` and `mergeFields`.** Replace the `timestamp1 > timestamp2` comparison in `packages/bdb/src/lib/merge-records.ts` with the chosen `compare`. Define what happens when the two are concurrent: pick a deterministic tie-break so both sides of a sync reach the same answer independently, and say what it is in the code comment.

7. **Fall back to the timestamp when the ordering is absent.** Records written before this change carry no ordering value. The comparison must handle one or both sides missing it without throwing and without silently preferring the newer format. Records already on disk must not need rewriting.

8. **Bump the serialization version if the on-disk format changes**, following whatever the existing versioning in `packages/serialization` requires, and confirm an older database still opens.

## Option A: vector clocks

Each writing device keeps a counter, and a record's metadata carries a map of device id to counter. A merge compares maps: one side dominates when every entry is greater than or equal and at least one is greater; otherwise the writes are concurrent and the tie-break decides.

- Correct regardless of clock skew, and it can *tell* that two writes were concurrent rather than guessing an order.
- Needs a stable device identity. The app has no such concept today, so one has to be created and persisted per install.
- The metadata grows with the number of devices that have ever written, per field. This database stamps metadata per field, so the cost is multiplied by field count and matters.
- Pruning entries for devices that no longer exist is a known hard problem and would need an answer eventually.

## Option B: hybrid logical clocks

Each record carries a single value combining wall time with a counter that only ever moves forward. On write the device takes the greater of its own clock and the last value it saw, then increments the counter. Comparison is a normal ordering on that pair.

- One value per field, the same size as a timestamp, so the metadata cost is unchanged.
- Still roughly human-readable and still sorts approximately by real time, so anything that displays or reasons about "when" keeps working.
- Cannot distinguish genuinely concurrent writes from ordered ones, so it does not fix conflicts, only stops skew reordering them.
- Requires that a device sees the other side's value during a sync to advance its own, which the merge already does.

## Unit Tests

- The new ordering module: `compare` for less-than, greater-than, equal and (Option A) concurrent; advancing for a local write; advancing on merge (Option B).
- `mergeValues` and `mergeFields` in `packages/bdb/src/lib/merge-records.ts`: incoming wins when it is later by the ordering even though its wall-clock timestamp is earlier. This is the test that would have caught the original fault.
- `mergeRecords`: the mixed case where one side carries an ordering value and the other does not.
- Serialization round-trip of the extended metadata, plus opening a database written before the change.
- The write paths in `packages/bdb/src/lib/collection.ts`: a write advances the ordering and stores it.

## Smoke Tests

- `apps/smoke-tests/tests/45-s3-share-replica-sync/test.sh` already covers an edit made on device reaching an encrypted S3 origin, and is the test that surfaced this. It should pass without the timing sensitivity it has now.
- A new CLI smoke test under `apps/cli/smoke-tests/`: build two databases, edit the same record in each with orderings set so the intended winner is the one with the *earlier* wall clock, sync, and assert the right value survives. The CLI can do this without any device, so it is the cheapest place to hold the behaviour.
- `apps/cli/smoke-tests/37-sync-edit-field` and the other sync suites must keep passing unchanged.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including the new bdb tests.
- `bun run test:everything -- --force` passes, which covers the CLI sync suites and both mobile suites.
- A database created before the change still opens and syncs.

## Notes

- **The motivating diagnosis is unproven, and reading the code casts doubt on it.** `mergeValues` returns the other side whenever one side's value is `undefined`, before any timestamp comparison. In the observed failure the origin had no `description` at all, so on that reading the device's value should have won whatever its timestamp said. Either the loss happens somewhere else (the pull leg, `cleanupMetadata`, or the push writing a record whose field metadata marks the field deleted rather than absent), or the field was not absent in the way assumed. Step 1 exists to settle this. It would be worth knowing before building either option.
- The observed skew was 26 seconds, emulator behind host, measured twice. The failure only appeared when the elapsed time between the origin write and the device edit was shorter than that, which is why it showed up under parallel load and not in isolation.
- `docs/plans/new/plan-sync-early-out.md` proposes a per-side change token to replace the content-hash early-out. It is not implemented (`bumpToken` appears nowhere in the codebase). It is adjacent to this work: both add a monotonic per-side value, and Option B in particular might share machinery with it. Worth reading the two together before starting either.
- The merge is field-level and the metadata is per field, so whatever is added here is paid per field per record. That is the main argument against Option A.
- Nothing here addresses what *should* happen when two devices genuinely edit the same field while disconnected. Option A can detect it; neither option decides it. That is a product question, not a merge question.
