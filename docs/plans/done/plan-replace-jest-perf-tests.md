# Replace Jest Performance Tests with Standalone TypeScript Runner

## Overview
The merkle-tree package contains a dedicated Jest performance test file (`packages/merkle-tree/src/test/performance.test.ts`) that measures timing characteristics of tree operations. These benchmarks do not belong in the Jest unit test suite because they are slow, flaky on loaded machines, and not testing correctness. The goal is to delete the Jest file and replace it with a standalone TypeScript script that Bun runs directly, wired up via a `package.json` script so it can be invoked from the release workflow.

## Issues

## Steps

1. **Create `packages/merkle-tree/perf-tests/run.ts`**
   - This is a standalone Bun script (no Jest), not a test file.
   - Import the same merkle-tree functions used in the Jest file: `addItem`, `updateItem`, `deleteItem`, `findItemNode`, `createTree`, `HashedItem` from `../src/lib/merkle-tree`.
   - Import `crypto` from Node.
   - Copy the three helper functions from the Jest file verbatim: `createHashedItem`, `measureTime`, `generateFileNames`.
   - Implement five named `async function` benchmark scenarios corresponding to the five Jest test cases:
     - `benchmarkAddFiles()` -- sizes 10, 100, 1000, 5000, 10000; threshold: `timePerFile < 8 ms`.
     - `benchmarkUpdateFiles()` -- build 10 000-file tree then update at indices 0, mid, last; threshold: `time < 10 ms` per update.
     - `benchmarkDeleteFiles()` -- build 10 000-file tree then delete at indices 0, mid, last; threshold: `time < 20 ms` per delete.
     - `benchmarkTreeDepthImpact()` -- sizes 1000 and 10000; verifies `timeRatio < sizeRatio * 2` and normalized update time `<= firstAvgTime * 2`.
     - `benchmarkBatchOperations()` -- baseline 1000-file tree, bulk add 100, bulk update 100, bulk delete 100; thresholds `avgTimePerUpdate < 1 ms`, `avgTimePerDelete < 1 ms`.
   - Each benchmark function prints its name, runs the measurement, checks its thresholds, and returns `true` (pass) or `false` (fail). On failure, print a `FAIL` line naming the benchmark and which threshold was exceeded. On pass, print a `PASS` line with the timing result.
   - Add a `main()` async function that calls all five benchmarks, collects pass/fail, prints a summary line (e.g. `3/5 passed`), and calls `process.exit(1)` if any benchmark failed.
   - Call `main()` at the bottom (not inside an IIFE -- just a top-level `main();`).

2. **Add a `perf` script to `packages/merkle-tree/package.json`**
   - Add `"perf": "bun run perf-tests/run.ts"` under `"scripts"`.

3. **Add a `perf` script to the root `package.json`**
   - Add `"perf": "bun --filter '*' perf"` under `"scripts"`.

4. **Delete `packages/merkle-tree/src/test/performance.test.ts`**
   - Remove the file entirely using a Bash tool call.

## Unit Tests
No new unit tests are needed. The performance runner is itself the replacement for the deleted tests. The remaining Jest tests in `packages/merkle-tree/src/test/` are unaffected.

Note: `packages/bdb/src/tests/sort-index-build.test.ts` contains one test named "should show performance metrics in final progress message" which checks that `SortIndex.build()` includes timing strings in its progress output. This is a functional correctness test, not a benchmark, and should remain in Jest untouched.

## Smoke Tests
- Run `bun run perf` from the repo root. Should exit 0 and print a PASS line for each of the five benchmarks.

## Verify
1. Run `bun run compile` from the repo root -- must succeed with no TypeScript errors.
2. Run `bun run test` from the repo root -- all existing unit tests must pass; `performance.test.ts` is gone so it no longer runs.
3. Run `bun run perf` from the repo root -- must exit 0 with all five benchmarks passing.
4. Confirm `packages/merkle-tree/src/test/performance.test.ts` no longer exists.

## Human Verification
- Run `bun run perf` and read the printed output to confirm all five benchmarks display timing numbers and a PASS result.
- Run `bun run test` and confirm the total test count has decreased by the number of tests that were in `performance.test.ts` (5 tests).

## Notes
- The `measureTime` helper is not async-aware; all merkle-tree operations being benchmarked are synchronous, so this is fine.
- Bun can run TypeScript directly without a compile step, so `perf-tests/run.ts` does not need a separate tsconfig or build output.
- Jest picks up files matching `*.test.ts` or `*.spec.ts` by default. `perf-tests/run.ts` does not match either pattern so Jest will never run it.
- Thresholds copied from the original Jest assertions. They are intentionally generous to survive loaded CI machines.
