# The CLI throws away its own output when it exits

## Overview

`73-s3-pagination` fails intermittently, and only when the machine is busy. It is not the listing, the paging or S3: the command works and then loses the end of what it printed. `find-orphans` prints one line per orphan and a `Found <n> orphaned file(s)` summary after them; on a failing run the captured output stops part way through the list (543, 548 and 649 lines of 1,100 were captured on three separate failures) and the summary never appears. The test reads the count out of that summary, gets nothing, and reports that the app enumerated zero objects, which is a description of the missing output rather than of anything that went wrong in S3.

The cause is `process.exit`. Measured directly with the pinned Bun: a program that writes 200,000 lines to a pipe whose reader waits two seconds before reading delivers 922 of them when it calls `process.exit`, and all 200,000 when it is allowed to end on its own. Buffered output only builds up when the output is a pipe, which is what a script capturing it gets and not what a terminal gets, and it drains more slowly the busier the machine is, which is why this is a load-dependent failure that never shows up by hand. Every `psi` command ends through `exit()` in `packages/node-utils/src/lib/termination.ts`, which calls `process.exit`, so every command can lose the end of its output, silently, with a zero exit code.

Two things need fixing: the output loss itself, and the fact that a test could read a truncated capture as a real answer of zero.

## Issues

## Steps

1. **Add the smoke test that proves the loss, and watch it fail.** Create `apps/cli/smoke-tests/89-piped-output/test.sh`, following the layout of `apps/cli/smoke-tests/73-s3-pagination/test.sh` (source `../lib/common.sh`, `print_test_header`, `get_test_dir`, `invoke_command`, `expect_value`, the `cleanup_and_show_summary` trap). Tests are discovered by `discover_tests` in `apps/cli/smoke-tests.sh` (`find smoke-tests -name "test.sh" | sort -V`), so creating the directory is all the registration needed. The test must:
   - Initialise a local database with `psi init`, then create enough unreferenced files under its `asset` directory that the command's output comfortably exceeds a pipe buffer (1,100 empty files is enough and costs a fraction of a second; no S3 and no media are involved, so the test is fast and has nothing to contend on).
   - Run `psi find-orphans` with its output going through a reader that does not read for a few seconds, so the writer's buffer fills exactly as it does under load. This is the whole point of the test: it must reproduce the failure every time on an idle machine, not wait for a busy one.
   - Assert that the last line the command prints is present in what was captured, and that the number of orphan lines captured equals the number of files created. Both assertions have to fail before the fix.
   - Run it with `bun run test:cli` and confirm it fails, and that it fails on the missing summary rather than on setup.

2. **Make the exit flush what it has written.** In `packages/node-utils/src/lib/termination.ts`, `exit()` currently calls `process.exit(code)` straight after the termination callbacks. Add a new module `packages/node-utils/src/lib/end-output.ts` exporting `endOutput(stream: NodeJS.WriteStream): Promise<void>`, which returns immediately for a stream that is absent or already ended and otherwise ends the stream and waits for its callback. It goes in a file of its own rather than in `termination.ts` because `termination.ts` imports the logger from `utils`, which the node-utils jest configuration will not transform, so a test importing it cannot run. Export it from `packages/node-utils/src/index.ts`. Have `exit()` await it for `process.stdout` and then `process.stderr` before `process.exit(code)`.
   - Ending the stream is the only thing that works in this runtime, and the plan should not be rewritten to use something tidier without measuring first: the write callback is never invoked, the `drain` event never fires, and `writableLength` always reads zero, so there is nothing to wait on and nothing to poll. An earlier attempt used `writableLength` and did nothing at all.
   - Nothing may write to those streams afterwards, so this is the last thing before the process ends.
   - Compile, then run the new smoke test and confirm it passes.

3. **Cover `endOutput` with unit tests.** Add `packages/node-utils/src/test/lib/end-output.test.ts` with a stand-in stream that records whether it was ended and hands the test its own callback, so the test decides when the ending completes. Cover: a stream with content waiting is ended and the promise does not settle until the callback runs; a stream already ended is left alone; an absent stream is tolerated.

4. **Fix the other exits that print and then leave.** `exit()` is not the only way a `psi` process ends. In `packages/node-utils/src/lib/termination.ts` the SIGTERM, SIGINT, uncaught-exception and unhandled-rejection handlers each log and then call `process.exit`, and `apps/cli/index.ts` calls `process.exit` in its `--version` option handler and in its own `uncaughtException` and `unhandledRejection` handlers, as does `apps/cli/worker.ts`. Every one of them can lose the message it just printed, which matters most for the error paths, where the lost message is the explanation. Route each through `endOutput` before exiting.
   - The two `log.verbose` calls in the `beforeExit` and `exit` handlers in `termination.ts` write after the streams are ended. Check what they do when the stream has been ended and make them harmless: either drop them or guard them on `process.stdout.writableEnded`.
   - Compile and run `bun run test:cli` and `bun run test:cli:encrypted`, which between them exercise the error paths.

5. **Stop the harness reading a missing answer as a number.** `parse_numeric` in `apps/cli/smoke-tests/lib/common.sh` returns its default of `0` when the pattern is not in the output, which is how "the summary line was missing" was reported as "the app enumerated 0 objects" and sent three separate investigations at S3. Give it a way to fail loudly: when the caller does not pass an explicit default and the pattern is absent, log an error naming the pattern and the last lines of the output it searched, and fail the test. Update the call in `apps/cli/smoke-tests/73-s3-pagination/test.sh` and any other caller that relies on the silent default, which `grep -rn "parse_numeric" apps/cli/smoke-tests` lists.
   - Shell is not unit tested here, so this step is finished when the full CLI suite passes.

6. **Confirm it under the conditions that produced it.** Run `bun run test:cli` three times, and run two copies of `bun run test:cli` at the same time, which is the interference check the repository prescribes for a suite that fails in company. `73-s3-pagination` must pass every time, and the new test 89 must pass on an idle machine, since it no longer depends on load at all.

7. **Write down the rule.** Add a short section to `docs/testing/README.md` saying that a command's output must be complete when something captures it, that this is what ending the standard streams before exiting is for, and that a test reading a value out of captured output must fail when the value is absent rather than substituting a default. Name test 89 as the test that holds the first half and `parse_numeric` as the place that holds the second.

## Unit Tests

- `packages/node-utils/src/test/lib/end-output.test.ts`: `endOutput` ends a stream that has content waiting and waits for the ending to complete; leaves an already-ended stream alone; tolerates an absent stream.

No other function changes shape. The changes in `apps/cli/index.ts`, `apps/cli/worker.ts` and the signal handlers are call sites of `endOutput`, and shell scripts are not unit tested in this repository.

## Smoke Tests

- New `apps/cli/smoke-tests/89-piped-output/test.sh`: a command whose output exceeds a pipe buffer, read by a reader that stalls, keeps every line and its final summary. This must fail before step 2 and pass after it, on an idle machine.
- Existing `apps/cli/smoke-tests/73-s3-pagination/test.sh`: unchanged in what it asserts, but its count must now come from a summary line that is really there, and step 5 makes it say so plainly when it is not.
- `bun run test:cli` run twice concurrently: both runs pass.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes, including the new `end-output` tests.
- `mise exec -- bun run test:cli` passes, including the new test 89 and test 73.
- Two concurrent `mise exec -- bun run test:cli` runs both pass.
- `mise exec -- bun run test:everything -- --force` passes.
- Test 89 fails when step 2 is reverted, and passes with it.

## Notes

**Measurements this plan rests on, all taken in this repository with the pinned Bun:**

- 200,000 lines written to a pipe with a reader that waits two seconds: 922 lines arrive when the program calls `process.exit`, 200,000 arrive when it is left to end on its own, and 200,000 arrive when it ends the stream before calling `process.exit`.
- `process.stdout.writableLength` reads `0` immediately after 200,000 writes, so it cannot be used to detect pending output. The `write` callback and the `drain` event were both tried and neither fires.
- Three separate failures of test 73 captured 543, 548 and 649 orphan lines out of 1,100, each with no summary line and an exit code of zero.

**Why the process cannot simply be allowed to end on its own.** That is the tidiest fix and it does work for local databases: `psi find-orphans` against a local path exits by itself in 0.4 seconds. It does not work for S3, where the AWS SDK's sockets keep the event loop alive, which is why `exit()` calls `process.exit` at all. An attempt to set `process.exitCode` and wait, with a timer as a backstop, made every S3 command wait for the timer and then truncate anyway. Ending the streams is what removes the loss without depending on the process being able to end quietly.

**This is not only about tests.** Any script that pipes `psi` output into something else can lose the end of it, with a zero exit code and nothing said. The smoke test failure is how it was noticed, not the extent of it.

**Left out on purpose.** The Electron main process and the mobile worker also end processes, but neither writes its output into a pipe that a script reads, so neither is in scope here. `45-s3-share-replica-sync` on Android also fails only under load, for an unrelated reason (a menu that opens later than the test waits), and needs its own plan.
