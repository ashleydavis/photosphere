# The CLI throws away its own output when it is piped

## Overview

`73-s3-pagination` fails intermittently, and only when the machine is busy. It is not the listing, the paging or S3: the command works and then loses the end of what it printed. `find-orphans` prints one line per orphan and a `Found <n> orphaned file(s)` summary after them; on a failing run the captured output stops part way through the list and the summary never appears. The test reads the count out of that summary, gets nothing, and reports that the app enumerated zero objects, which is a description of the missing output rather than of anything that went wrong in S3.

**The cause is not `process.exit`, which is what this plan said when it was written.** That reading was tested and is wrong, and the fix it proposed (ending the standard streams before exiting) was implemented, measured, and removed again because it changed nothing. What was measured instead, in this repository with the pinned Bun:

- The loss starts the moment the process has a Worker, and the CLI creates a pool of them as soon as it opens a database. A program that writes into a pipe before opening a database loses nothing; the same program after `loadDatabase` delivers 8,127 bytes of 220,890.
- It is dropped as it is written, not queued. Waiting six seconds before ending, ending the streams and waiting for their callbacks, and letting the process end on its own with no `process.exit` at all each deliver exactly the same 8,127 bytes. `console.log` and `fs.writeSync(1, ...)` lose it alike, and `writableLength` reads zero throughout.
- `fs.writeSync` on that descriptor raises EAGAIN when the far end is full rather than waiting, and can write fewer bytes than it was given. A write loop that finishes a partial write and waits out EAGAIN delivers all 220,890 bytes. One line took 2,566 waits of a millisecond while the reader had not started, which is exactly what a blocking write would have done.
- Opening `/dev/stdout` for a file description of its own also delivers all 220,890 bytes on Linux, and does nothing at all on macOS, where `/dev/fd/1` is a dup that shares the flags rather than a fresh description. That was the first fix, and macOS CI caught it: test 89 delivered 871 lines of 3,000 there while passing on Linux.

Two things needed fixing: the output loss itself, and the fact that a test could read a truncated capture as a real answer.

## Issues

## Steps

1. **Add the smoke test that proves the loss, and watch it fail.** `apps/cli/smoke-tests/89-piped-output/test.sh` prints 3,000 orphans into a reader that sleeps before taking a byte, so it reproduces the loss on an idle machine rather than waiting for a busy one, and asserts every line, the summary and the last line after it. Watched failing with the fix disabled: 108 lines of 3,000 arrived and no summary.

2. **Have the CLI write its own bytes and wait for them.** `apps/cli/src/lib/console-output.ts` exports `writeOutputLine` and `writeErrorLine`, which write to descriptors 1 and 2 in a loop that finishes a partial write and waits out EAGAIN, and give up quietly on EPIPE the way Node's own streams do. `apps/cli/src/lib/log.ts` and `apps/cli/src/lib/worker-log-bun.ts` call them for every line they print, which is every line the CLI prints: no command writes to the console directly. Nothing here is platform-specific, which the `/dev/stdout` version it replaced was.

3. **Stop the harness reading a missing answer as a number.** `parse_numeric` in `apps/cli/smoke-tests/lib/common.sh` answered its default of `0` when the pattern was absent, which is how "the summary line was missing" was reported as "the app enumerated 0 objects". It now answers with nothing, on stderr says which pattern was missing and shows the last lines it searched, and returns non-zero; a caller that wants a default for an absent pattern passes one explicitly. `73-s3-pagination` treats the missing summary as a failure of its own.

4. **Confirm it under the conditions that produced it.** `bun run test:cli` passes with test 89 in it, and two copies of `bun run test:cli` at the same time both pass, which is the interference check this repository prescribes for a suite that fails in company.

5. **Write down the rule.** `docs/testing/README.md` has a section saying that a command's output must be complete when something captures it, what makes it incomplete here, and that a test reading a value out of captured output must fail when the value is absent.

## Unit Tests

None. `writeOutputLine` and `writeErrorLine` differ from `console.log` only in which operating system file description the bytes go to, which no jest test can observe: it takes a pipe with a reader that has not started, which is what smoke test 89 is. There is nothing else in the module to assert that would not be asserting that `fs.writeSync` was called.

The shell change in `parse_numeric` is not unit tested, because shell is not unit tested in this repository.

## Smoke Tests

- New `apps/cli/smoke-tests/89-piped-output/test.sh`, as above. It must fail with the fix removed and pass with it, on an idle machine.
- Existing `apps/cli/smoke-tests/73-s3-pagination/test.sh`: unchanged in what it asserts, but its count now comes from a summary line that is really there, and it says so plainly when it is not.
- `bun run test:cli` run twice concurrently: both runs pass.

## Verify

- `mise exec -- bun run compile` is clean.
- `mise exec -- bun run test` passes.
- `mise exec -- bun run test:cli` passes, including the new test 89 and test 73.
- Two concurrent `mise exec -- bun run test:cli` runs both pass.
- `mise exec -- bun run tev` passes.
- Test 89 fails when step 2 is reverted, and passes with it.

## Notes

**What the earlier version of this plan got wrong, and why it is worth recording.** It measured 200,000 lines into a slow pipe and found 922 delivered on `process.exit` and all 200,000 when the stream was ended first, and concluded that the exit was throwing away queued output. That measurement was taken in a program with no Worker in it. In the CLI, where the Workers exist, ending the stream delivers no more than exiting does, because nothing is queued to flush: the bytes were already gone. The fix that follows from the wrong reading looks like it works (a small program does deliver everything) while the real failure is untouched, which is exactly the kind of fix a smoke test has to be written before, not after.

**This is not only about tests.** Any script that pipes `psi` output into something else could lose the end of it, with a zero exit code and nothing said. The smoke test failure is how it was noticed, not the extent of it.

**Left out on purpose.** The Electron main process and the mobile worker also print, but neither writes its output into a pipe that a script reads, so neither is in scope here. `45-s3-share-replica-sync` on Android also fails only under load, for an unrelated reason (a menu that opens later than the test waits), and needs its own plan.

**Found on the way and not fixed here:** `bun run test:cli -- <number>` exits 1 even when the test passes, because the baseline capture at the end of the script is handed the test number as its target name. `scripts/run-mobile-tests.sh` exists to solve exactly that for the mobile suite; the CLI suite needs the same treatment and it is a separate change.
