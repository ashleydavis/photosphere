# Get the CLI smoke tests under two minutes

## Overview

`bun run test:cli` runs 80 tests and takes 3m 17s on a quiet machine (measured 2026-08-12, 24 cores / 62GB, all 80 passing) and 5m 41s on a busy one (measured 2026-08-13 on the same machine, all 80 passing, with five Android emulators and another worktree's Electron and CLI suites running alongside at load average 60 to 114). The target is under 2 minutes on a quiet machine. The CLI itself is not what is slow: a `psi summary` against a five-file database costs 0.50s end to end from source and 0.40s from the compiled binary, and the suite makes 412 CLI invocations in total.

Three things account for the time. `run_parallel` in `apps/cli/smoke-tests.sh:528` runs the tests in batches of five behind a barrier, so a batch costs as much as its slowest member and every other lane in it stands idle until that one finishes: in the measured run the sum of the batch maxima is 283s against 182s of work per lane, which is 101s (36% of the test phase) spent doing nothing. The batches also run in test-number order, so the S3 tests, which are among the longest, are the last thing started and set the tail. And 18 of the 80 tests each build the identical five-file database from scratch before they begin, at a measured 5s a time (`init` 0s, PNG 1s, JPG 1s, MP4 2s, the multiple-files directory 1s), which is 90s of the suite's work spent producing 18 identical copies of a 7.5MB directory that takes under a second to copy.

This plan replaces the batch barrier with the rolling pool the Electron suite already uses, extracting that pool into a library so there is one implementation rather than a copy per suite; starts the longest tests first; builds the five-file database once per run and hands every test a copy; and runs the tests against the compiled binaries instead of the TypeScript sources, which the suite can already do behind `--binary` and which costs 0.79s to build all three. Everything here is shell and test-side. No app code changes.

## Issues

## Steps

1. **Add `scripts/lib/test-pool.sh`.** A new sourced library beside `allocate-test-temp-dir.sh`, `process-control.sh`, `test-timeout.sh` and `test-concurrency.sh`, holding the rolling pool that `run_parallel_pool` at `apps/desktop/smoke-tests.sh:219` currently owns. Same comment voice as its neighbours, written for bash 3.2 (no associative arrays, no `wait -n`).
   - `TEST_POOL_POLL_INTERVAL=0.1`, with the comment the desktop copy carries: this is what decides how long a freed slot sits empty, and the poll itself is one `kill -0` per running test.
   - `run_test_pool <n> <start_fn> <report_fn> <test...>` keeps at most `n` tests in flight and refills a slot the moment one finishes. It calls `start_fn <test_sh>`, which must start exactly one background job and leave its pid in `TEST_POOL_JOB_PID` and whatever the reporter needs (the test's temp directory) in `TEST_POOL_JOB_CONTEXT`. Globals rather than a return value on stdout, and this is load-bearing: a job started inside a command substitution belongs to that subshell, so the pool could neither `wait` for it nor read its exit status. When a slot's pid stops answering `kill -0`, the pool `wait`s it for the status and calls `report_fn <status> <test_sh> <context>`.
   - Hold the slots in three indexed arrays (`test_pool_pids`, `test_pool_tests`, `test_pool_contexts`), as the desktop copy does.

   Impact: none on its own. It is what stops step 2 from being a second copy of an 80-line scheduler.

2. **Move `apps/desktop/smoke-tests.sh` onto the library.** Source `scripts/lib/test-pool.sh` beside the existing sources at the top of the file, delete `run_parallel_pool` (line 219) and `POOL_POLL_INTERVAL` (line 167), and add `start_desktop_pool_job` holding the body that allocates the temp directory, prints the `RUN` line and starts the background job, and keep `report_pool_result` as the reporter (changing its signature to `<status> <test_sh> <context>` and taking the pass/fail counters from the two variables `run_mixed` already owns rather than by name). Change `run_mixed` to call `run_test_pool`. Nothing about the desktop suite's output or behaviour changes.

   Impact: none on the CLI suite. This step is what makes the extraction real rather than a copy left behind.

3. **Replace `run_parallel` with the pool, in `apps/cli/smoke-tests.sh:528`.** Source `scripts/lib/test-pool.sh` beside the existing sources at lines 31, 42 and 45. Split the current function into `start_cli_pool_job <test_sh>` and `report_cli_pool_result <status> <test_sh> <context>`, and have `run_parallel` call `run_test_pool` and then `print_failed_logs` and `print_summary` exactly as it does now. Everything the current batch runner does must survive the move:
   - The Bun-crash retry (lines 567 to 594), including the `.signal-death` rename, the announcement, and the freshly allocated directory for the retry.
   - The skip status (`TEST_SKIPPED_EXIT_CODE`), counted and printed separately and never folded into the pass total.
   - The timeout status, reported by `report_test_timeout` and named as a timeout rather than as an assertion failure.
   - The duration read from `test-duration.txt` and the failing test's log path pushed onto `FAILED_TEST_LOGS`.
   Since the pool reports three outcomes rather than two, `run_test_pool` in step 1 takes only the reporter and lets the reporter own its counters, so the CLI's skip counter needs nothing from the library.

   Impact: the largest single win. The measured batch phase was 283s against 182s of per-lane work, so a pool that never idles a lane takes about 36% off the test phase.

4. **Take the pool width from the core count, in `apps/cli/smoke-tests.sh`.** Source `scripts/lib/test-concurrency.sh` and set `PARALLEL_N` from `resolve_test_parallel 5` instead of the literal `5` at line 76, leaving `--parallel N` on the command line winning over both. Print the width the run chose, as the desktop suite does ("Running up to 6 tests at a time."), because it is no longer a constant in the file. Update `show_usage` (line 879) to say the default comes from the core count and to name `PHOTOSPHERE_TEST_PARALLEL`.

   Impact: small on its own here (24 cores gives 6 against the current 5, a measured 24/4 capped at `TEST_CONCURRENCY_MAX`). Its value is that `scripts/test-everything-parallel.sh` can hand this suite a share when ten lanes are sharing the machine, which today it cannot.

5. **Start the longest tests first, in `apps/cli/smoke-tests.sh`.** Add `is_slow <test_sh>` returning 0 when the test's directory holds a `.slow` marker file, mirroring `is_sequential` at `apps/desktop/smoke-tests.sh:91`, and `order_slow_first <test...>` printing the marked tests first with the relative order of everything else preserved. Call it in `run_all_tests` (line 744) on `all_scripts` before handing them to `run_parallel`. Then create empty `.slow` files in the directories of the tests measured longest. From the 2026-08-13 run those are `22-replicate-changes` (46s), `25-remove` (45s), `69-s3-sync` (39s), `21-compare-changes` (39s), `17-replicate` (36s), `24-repair-ok` (35s), `67-s3-replicate` (31s), `70-s3-verify-repair` (30s), `18-verify-replica` (27s), `37-sync-edit-field`, `38-sync-edit-field-reverse`, `36-sync-copy-to-original` and `19-replicate-second` (23s each). **Choose the final set from a measurement taken after step 6, not from this list**: step 6 takes most of the cost out of tests 17 to 26, so several of them will no longer be slow, and a marker set that has gone stale schedules the wrong test first while looking deliberate. Read the durations from the `PASS` lines the run prints.

   Impact: removes the tail. Numeric order puts the 30 to 40s S3 tests last, so today the run ends with one long test and five idle lanes.

6. **Build the five-file database once and hand every test a copy.** Three parts:
   - In `apps/cli/smoke-tests/lib/common.sh`, add `create_db_with_5_files <db_dir>`. When `PHOTOSPHERE_SMOKE_FIXTURE_5_FILES` names a directory that exists, `cp -r` it to `<db_dir>` and copy the fixture's `photosphere-test-uuid-counter` to `$TEST_TMP_DIR/photosphere-test-uuid-counter`. Copying the counter is not tidiness: `TestUuidGenerator` in `packages/node-utils/src/lib/test-uuid-generator.ts` counts from zero per `TEST_TMP_DIR`, so a test that copies the fixture and then adds an asset would otherwise be handed counter 1 again and mint a UUID the copied database already contains. When the variable is unset or names nothing, fall back to running `init` followed by the current `populate_db_with_5_files` body, so a test run on its own from the command line still works.
   - In `apps/cli/smoke-tests.sh`, add `build_shared_fixtures` and call it from `run_all_tests` after `check_tools` and before the tests start. It allocates a directory with `allocate_isolated_test_dir "fixture-db-5-files"` (never a fixed path: two runs out of one checkout must not share it), builds the database inside it with `TEST_TMP_DIR` pointed at that directory so the counter file lands beside it, and exports `PHOTOSPHERE_SMOKE_FIXTURE_5_FILES`. A failure to build the fixture must fail the run loudly, not fall through to 18 tests each rebuilding it.
   - Replace the `init` line and the `populate_db_with_5_files` line with a single `create_db_with_5_files "$TEST_DB_DIR"` in each of the 18 callers: `10-summary`, `11-list`, `12-export`, `13-verify`, `14-verify-full`, `15-detect-deleted`, `16-detect-modified`, `17-replicate`, `18-verify-replica`, `19-replicate-second`, `20-compare`, `21-compare-changes`, `22-replicate-changes`, `24-repair-ok`, `25-remove`, `26-repair-damaged`, `67-s3-replicate` and `70-s3-verify-repair`. Delete `populate_db_with_5_files` once nothing calls it.

   Verified as safe to copy before writing this: a built database holds no absolute path and no machine path (checked with `grep -r` over a real one for both the temp root and the home directory, and `config.json` is `{}`), so a copy is indistinguishable from a build. The one thing a copy shares that a build does not is the database id, and no test needs two databases from this helper to be unrelated: `42-replicate-unrelated-fail` builds its pair with two bare `init` calls and is untouched, and `67-s3-replicate` calls the helper once (its second match is a comment).

   Impact: 90s off the suite's work, about 15s of wall clock at width 6. It is also the step that changes which tests are slow, which is why step 5's markers are chosen after it.

7. **Run the tests against the compiled binaries.** Make `run_all_tests` build the three binaries and set `USE_BINARY=true` for the run, and export `USE_BINARY` so the test scripts see it (`apps/cli/smoke-tests/lib/common.sh` reads it at lines 46, 74 and 102 and today never sees anything but the unset default). Reuse the build blocks already in `test_setup` (lines 312 to 365) rather than writing new ones, lifting them into a `build_cli_binaries` function that both call. Add `--source` as the inverse of the existing `--binary` flag so a run can still be pointed at the TypeScript.

   Measured: `psi summary` costs 0.50s from source (0.52, 0.49, 0.50) and 0.40s from the binary (0.39, 0.41, 0.41); `--version` costs 0.22s against 0.13s. Building all three is 0.79s total (psi 0.34s, mk 0.23s, bdb 0.22s), so the prologue cost is noise.

   Impact: about 41s off the suite's work (412 invocations at roughly 0.10s each), about 7s of wall clock. It also means the suite exercises what actually ships. Watch for tests that assert on output the `--minify` build renders differently; any that fail here are a real difference between what is tested and what is shipped, and must be fixed rather than worked around by leaving that test on the source path.

8. **Update `apps/cli/README.md`.** Say that the suite runs a rolling pool sized from the core count, that `--parallel N` and `PHOTOSPHERE_TEST_PARALLEL` override it, what the `.slow` marker means and how the marked set is chosen, that the run builds the five-file database once and copies it, and that the tests run against the compiled binaries with `--source` to opt out.

## Unit Tests

None, and this is deliberate rather than an omission. `CLAUDE.md` says not to write tests for shell scripts and not to create `*.test.sh` files, and every change in this plan is shell: `scripts/lib/test-pool.sh`, the runner functions in `apps/cli/smoke-tests.sh` and `apps/desktop/smoke-tests.sh`, `create_db_with_5_files` in `apps/cli/smoke-tests/lib/common.sh`, and the 18 test scripts. What proves the pool works is the two suites it runs, both of which are checked below.

No TypeScript changes, so no Jest test changes.

## Smoke Tests

The suites this plan changes are themselves the end-to-end coverage, so the checks are the suites plus the cases the changes could break:

- `bun run test:cli`: all 80 tests pass, under 2 minutes, three consecutive runs on a machine with nothing else running on it.
- `bun run test:cli -- --sequential`: all 80 pass. This is the serial cost with no overlap, and it is the check that step 6 did not make a test depend on being run beside another.
- `bun run test:cli -- 13` and `bun run test:cli -- verify`: a single test by number and by name passes, run with no fixture built, proving `create_db_with_5_files` falls back to building the database.
- `bun run test:cli -- 21`: passes. It is the test that adds an asset after the copy, so it is the one that fails if the UUID counter is not copied with the fixture.
- `bun run test:cli -- --parallel 2`: reports a width of 2 and passes, so the flag still beats the detected width.
- `PHOTOSPHERE_TEST_PARALLEL=3 bun run test:cli`: reports 3 and passes. Set to `0`, `-1` and `abc`: each refused with a message naming the value and a non-zero exit.
- `bun run test:cli -- --source`: all 80 pass against the TypeScript, so the source path is not left to rot.
- One test made to fail on purpose: reported as `FAIL`, the summary counts it, its log is dumped after the summary, and nothing is left running.
- One test made to skip: reported as `SKIP`, counted separately, and never folded into the pass total.
- The run interrupted with SIGINT to its process group: prints "Interrupted.", exits non-zero, and leaves no `psi`, `bun` or MinIO process of its own behind.
- `bun run test:electron`: all 34 pass, and no slower than the 1m 28s it runs at today, proving step 2 did not regress the suite the pool came from.
- `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, `bun run test:cli:sync`, `bun run test:cli:write-lock` and `bun run test:cli:hash-cache`: each passes. They share `apps/cli/smoke-tests/lib/common.sh` with the suite being changed.

## Verify

- `bash -n` parses cleanly for every file changed, as a set, after each round of edits.
- `bun run compile` passes.
- `bun run test` passes.
- `bun run test:cli` runs all 80 tests green in under 2 minutes, three consecutive runs, with the durations recorded in a Result section added to this plan.
- `bun run test:electron` passes, all 34 green.
- `bun run test:parallel -- --scripts "test:cli test:electron"`: each suite alone and then every pair, including each against a second copy of itself. The self-pair is what catches a fixture directory or a pool file that is shared when it should not be.
- `bun run test:everything -- --force` passes, and the CLI lane inside it is reported.
- `bun run emu:and:pool:status` is run immediately before `test:everything` and its exit code reported, since that run includes the Android suite.

## Result

Measured on 2026-08-13 on the 24 core / 62GB machine, with four Android emulators up throughout and another worktree's suites running for part of it, so none of these was taken on a quiet machine. The load average at each run is given where it matters.

- **`bun run test:cli`: 1m 15s, 1m 18s, 1m 15s, all 80 tests green, three consecutive runs** (load average 66, 31 and 15 at the end of each). The baseline was 3m 17s quiet and 5m 41s busy, so this is under the 2 minute target even on a machine that was not quiet.
- Sequential (`--sequential`): all 80 green in 6m 2s. This is where the `.slow` markers came from: the longest tests alone are 69-s3-sync 25s, 70-s3-verify-repair 16s, 67-s3-replicate 14s, 64-config-timestamps 14s, 74-s3-failures 12s, 72-s3-paths 12s, 37-sync-edit-field 12s, 38-sync-edit-field-reverse 11s, 36-sync-copy-to-original 11s, 35-sync-original-to-copy 10s, 41-replicate-deleted-asset 9s, and 77-s3-large-file, 68-s3-encrypted, 40-sync-delete-asset-reverse and 39-sync-delete-asset at 8s. Everything at 8s or more is marked. Ordinary tests now run in 0 to 3s each, which is what the shared fixture and the compiled binaries did to them.
- `--source`: all 80 green in 1m 29s, so the TypeScript path still works and costs about 14s more than the binaries over a whole run.
- `--parallel 2`: reported "up to 2 at a time", all 80 green in 3m 20s. `PHOTOSPHERE_TEST_PARALLEL=3`: reported 3, all 80 green in 3m 47s. Set to `0`, `-1` and `abc` the run is refused with a message naming the value and exit 1.
- Single tests with no fixture built, which is the fallback path in `create_db_with_5_files`: test 13 by number, `verify` by name and test 21 all pass.
- A test made to fail on purpose is reported as `FAIL`, counted (1 of 82 failed), and its log dumped after the summary; a test made to skip is reported as `SKIP` and counted separately (1 skipped), never folded into the pass total.
- The run interrupted mid-flight prints "Interrupted.", exits 130, and leaves nothing in its process group. This was done with SIGTERM rather than SIGINT, because the harness the check ran from starts commands with SIGINT ignored and bash will not install an INT trap it inherited as ignored. The suite routes both signals to the same handler.
- `bun run test:electron`: all 34 green in 1m 31s, against 1m 28s before the pool was extracted, which is the same within noise.
- `bun run test:parallel -- --scripts "test:cli test:electron"`: no interference across all three combinations, self-pairs included.
- `bun run test:everything -- --force`: all 13 scripts green in 13m 45s across 12 lanes, with `bun run emu:and:pool:status` reporting 4 pool emulators on the LAN bridge and exit 0 immediately beforehand. The CLI lane took 4m 07s inside that run, which is the whole machine being shared by 12 lanes at once rather than by one suite; the other CLI suites that share `smoke-tests/lib/common.sh` all passed in it (`test:cli:encrypted` 4m 08s, `test:cli:lan-share` 1m 26s, `test:cli:sync` 1m 05s, `test:cli:write-lock` 3m 03s, `test:cli:hash-cache` 18s).

## Deviations from the plan

- **Step 5 was implemented and then removed at the human's request.** `.slow` markers, `is_slow` and `order_slow_first` are gone, and `CLAUDE.md` now bans marker files outright: a marker records a judgement once and nothing re-checks it, so it goes stale silently. The suite starts its tests in numeric order again. The three runs recorded below were taken with the markers in place; three more taken after removing them were 1m 20s, 1m 19s and 1m 24s, all 80 green, so the ordering was worth nothing measurable once the shared fixture and the compiled binaries had flattened the per-test costs.
- **Step 6 said to put `create_db_with_5_files` in all 18 callers including `70-s3-verify-repair`, whose database lives in an S3 bucket.** A directory cannot be copied into a bucket, so `create_db_with_5_files` detects a non-local destination and builds instead. Test 70 calls the same helper and gets the build path; `populate_db_with_5_files` therefore stays rather than being deleted, because the helper's fallback and the fixture builder both call it.
- **The fixture is built by `apps/cli/smoke-tests/lib/build-5-file-fixture.sh` rather than by code in the runner.** The runner does not source `smoke-tests/lib/common.sh`, so building it in the runner would have meant a second definition of what the five-file database is. The script sources common.sh and calls the same `populate_db_with_5_files` every test used to call.
- **`USE_BINARY` is exported in `main` as well as in `run_all_tests`.** Without that, `--binary` on a single test does nothing at all, which is what the flag has always done.
- **`apps/bdb-cli/bin/` added to `.gitignore`.** Every full run now builds bdb, and only `apps/cli/bin/` and `apps/mk-cli/bin/` were ignored, so a run left the working tree dirty.

## Notes

- **Where the measurements came from.** The 5m 41s run on 2026-08-13 was taken on a machine carrying load average 60 to 114 from five Android emulators and another worktree's suites, so its absolute numbers are inflated. What is not inflated is the structure it exposes, because both halves of the ratio suffer the same contention: 912s of test time against 283s of batch wall clock, where a pool at width 5 would have taken 182s. The 3m 17s quiet baseline is the figure the 2 minute target is measured against, and it was recorded on 2026-08-12 in the verification of the Electron suite's speed-up.
- **A shared MinIO for the 13 S3 tests was considered and left out.** Each of `65` through `77` starts its own server through `start_s3_emulator` and each pays a start and a bucket seed, which is roughly 2 to 3s a test, about 30s of the suite's work and perhaps 6s of wall clock. Sharing one server means every test taking a bucket of its own, because `EMULATOR_BUCKET` in `scripts/s3-emulator.sh:27` is a single fixed name, and it means a server whose lifetime spans the run rather than one test, which is a new thing to leak. The target is met without it. If a later run needs more, this is the next lever and it is worth its own plan.
- **Dropping the `bun run` wrapper was measured and is not worth doing.** `bun index.ts --version` costs 0.21s against `bun run start -- --version` at 0.23s, so removing the wrapper process saves about 20ms per invocation, roughly 8s of work across the suite and under 2s of wall clock. Step 7 gets five times that and gives the suite the shipped binary as a bonus.
- **`TEST_CONCURRENCY_MAX` is left at 6.** CLI tests are lighter than Electron tests, which are a whole app and an X server each, so this suite could take a wider slice of a 24 core machine. Raising the constant would widen the Electron suite too, and the target is met at 6. If the width turns out to be the binding constraint after this work, raise it for this suite by passing a cap rather than by changing the shared number.
- **The `.slow` marker will go stale, and that is a known cost.** It is chosen by measurement at one moment and nothing re-checks it. The alternative, ordering by durations recorded from the previous run, needs a cache that survives between runs and a decision about what a first run on a fresh checkout does. The marker matches what `apps/desktop/smoke-tests.sh` and the mobile suite already do, and a stale marker costs tail latency rather than correctness.
- **What is deliberately not touched.** The per-test temporary directory allocation, the Bun-crash retry, the timeout handling and the traps that kill the process tree all stay exactly as they are: they are what makes the suite survive running beside another copy of itself, and none of them is on the critical path. The `sleep 1` in `64-config-timestamps` and the `sleep 0.5` polls in `78-dbs-share-cancel` and `79-secrets-share-cancel` stay too; the first is waiting for a clock to tick over and the others are already at half a second.
- **`apps/cli/test/tmp` is still the suite root and is still a fixed in-tree path**, set at `apps/cli/smoke-tests.sh:58` and deleted at the top of `run_all_tests`. Nothing in this plan makes that worse, and step 6 deliberately allocates the fixture through `allocate_isolated_test_dir` rather than putting it there, but two runs of `test:cli` from one checkout still race on that `rm -rf`. Worth fixing, and not here.
