# Hash files natively on mobile, and keep it only if it measurably helps

## Overview

Automatic import on a phone spends almost all of its time hashing, and the hashing is a pure-JS SHA-256 running inside the embedded JS engine. Measured on a Pixel 6 it manages 0.75 MB/s, against 500 to 900 MB/s for `sha256sum` on the same handset: roughly 700 times slower. A first backup of a 2,186 photo library was observed importing at about 1.5 photos a minute, which is around a day of work. `CryptoHost` implements RSA and nothing else, so there is no native hash to call.

This moves hashing to a native host function. **It is kept only if it substantially improves automatic import on a real device, and reverted if it does not.** A change that is faster on paper, faster on an emulator, or faster by a margin small enough to argue about is not kept. The measurement is not an afterthought here: it is the reason the work is being done, so it is taken before anything is written and repeated after.

What is measured is a **full automatic import**: listing the library, exporting each photo out of it, hashing, thumbnails, display versions and database writes, end to end. Hashing is 99.1% of a bare scan, but whether it dominates a full import has never been established, and that is the question the decision turns on. **Hashing is also reported as its own figure inside that total**, so the change can be seen doing what it claims to do even when the total barely moves.

Both paths are measured, before and after: the **hash-computed** path, where every photo is exported and hashed because the hash cache is empty, and the **hash-cached** path, where the cache answers and no hashing happens. The first is what this change is aimed at. The second is measured because it is what a phone does on every run after the first, and because a change that speeds the first up while slowing the second down has not helped.

## Issues

- [x] The measuring harness is not in the tree. It was written in a scratch worktree, used for the numbers already in `docs/performance/mobile-auto-import-scan.md`, and discarded. Rebuilding it means adding test-only scaffolding to app code (a `perf-import` worker task, and a command for it in the shared test driver and control bridge), which this repository requires the human to approve before any of it is written. **Approved, on the condition that the whole plan is carried out in a git worktree.**
- [x] Decide whether the before and after figures cover the scan only or a full automatic import. **Full import, with hashing called out separately within it.**

## Steps

1. **Measure the current speed, before changing anything.** Rebuild the measuring harness as a full-import one: a worker task that runs a real automatic import and reports its elapsed time split by stage, with hashing as its own line, plus items seen, cache hits and misses, bytes hashed and failures. Take both figures on the real phone: a cold pass with the hash cache deleted, and the warm pass straight after it over the same items. Write the numbers, the exact method, and the device and library they came from into the before-and-after doc (see below). Everything after this is judged against it, so a method that cannot be run again later is no use.

   Write the doc as soon as there is anything in it to read, and update it as each figure arrives, rather than holding everything back until the end.

2. **Add a native file-hashing host function** on Android (`CryptoHost.java`, reached through `HostBridge.java`) and iOS (`CryptoHost.swift`, `HostBridge.swift`), following `docs/adding-android-native-functions.md` and `docs/adding-ios-native-functions.md`. It takes a sandbox-relative path and returns the digest.

3. **Call it from the hashing path.** `validateAndHash` in `packages/node-api/src/lib/hash.ts` already has the file's path, so the bytes never have to cross the bridge. Route the mobile case through the host function and leave every other platform on `node:crypto`.

4. **Measure again, the same way.** The same phone, the same library, the same harness, both the cold and the warm pass. Add the after figures to the doc beside the before ones as soon as they are taken.

5. **Decide, and act on the decision.** If automatic import on the phone is substantially faster, keep it and record both figures. If it is not, revert the whole change rather than leaving it in on the argument that it ought to help. "Substantially" is not left to be argued about after the fact: **the cold full import must be at least several times faster on the phone, and the warm pass must not be slower.** A few per cent, or a win that only shows on an emulator, means the change goes. Hashing on its own getting hundreds of times faster is not the test and does not save the change: if hashing collapses to nothing and the full import barely moves, the answer is that the bottleneck is somewhere else, and the doc records where.

6. **Write the before-and-after doc.** `docs/performance/native-hashing-before-and-after.md`: the two sets of figures side by side, the method, the device, the library, and the decision that came out of them. This is not written at the end from notes; it is started at step 1 and added to as each measurement lands, so the numbers can be read while the work is still going on. It stays in the repository whichever way the decision goes, because a change that did not help is worth exactly as much to the next person as one that did.

Each step is finished only when the code compiles and the tests pass.

## Unit Tests

- The new hashing path in `packages/node-api/src/lib/hash.ts`: the digest it produces for known bytes matches what `node:crypto` produces for the same bytes. A hash that is fast and wrong is worse than a slow one, and every database already written depends on these digests matching.
- Whatever selects between the native and the Node path: each is chosen where it should be.
- The Android host function gets a JVM test under `apps/android-frontend/android/app/src/test/...` covering a known input and its expected digest, and the empty-file case.

## Smoke Tests

- `apps/smoke-tests/tests/47-auto-import/test.sh` must keep passing unchanged. It imports real photos through the real path, so a hash that disagrees with the old one shows up as an import that fails or re-imports.
- The hash cache assertion in that test matters more than usual here: a warm run must still hit the cache for every item. If the digest changed, nothing would hit and every run would re-import the library.
- Add an end-to-end check that a database written before the change still verifies afterwards, using a fixture from `test/dbs`.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes.
- `mise exec -- bun run test:everything -- --force` passes.
- The before and after measurements are both recorded in `docs/performance/native-hashing-before-and-after.md`, both cover the cold and the warm pass, both were taken on the same real phone the same way, and the after is substantially better. If it is not, the change is gone and the plan is closed as "tried, did not help", with the numbers kept so nobody tries it again on the same reasoning.

## Notes

**Where the time actually goes, measured:** 99.1% of a cold scan is hashing, on both devices tested. Copying photos out of the photo library is 0.8%. Listing the library is tens of milliseconds. Nothing else is worth touching until hashing is dealt with.

**Hash the file, not the stream.** `createHash` in the crypto shim is a streaming object, and making each `update` a host call would send every chunk across the bridge base64-encoded, which could easily be slower than the JS it replaces. `validateAndHash` has the path, so a host function that opens and hashes the file natively moves no bytes across the bridge at all. That is where the win is.

**Leave the other callers alone.** `createHash` is also used for the checksum on every serialized file and for the encrypted-file header. Those are small and frequent rather than large and rare, and changing them is a different question with a different answer.

**Correctness is not negotiable.** These digests are the identity of every asset and the key of the hash cache. A digest that differs from `node:crypto` by so much as a byte makes every existing database look wrong, and the failure would be silent: photos re-import and the cache never hits.

**A caution about the target.** The end-to-end rate observed on the device was about 1.5 photos a minute, while the scan-only benchmark predicted about 36. The difference is the import work the benchmark never measured: thumbnails, display versions and database writes. Hashing dominates the scan; whether it dominates a full import has not been established. If it does not, this change will not move the number by much, and that is exactly the case step 5 exists for.

**The phone was also out of swap** during the observation, with the app holding 1.66 GB of native heap. That is a separate problem and it makes any measurement taken in that state unreliable. Take the baseline on a phone that is not thrashing.
