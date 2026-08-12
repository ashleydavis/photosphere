# Get every pair green in one run of the parallel check

## Overview

Run `bun run test:parallel` and keep fixing what it reports until a single run comes back green on every pair. Each fix is simple, minimal and direct, commented with what it fixes and why it was needed, and committed on its own.

## Issues

<empty>

## Steps

1. Run `bun run test:parallel`.

2. If it exits 0 with every combination reported `ok`, stop. The work is done.

3. Otherwise read `tmp/parallel-check/<timestamp>/report.txt` and the failing side's log. Find what the two scripts contend on.

4. Fix that one thing with the smallest change that removes it. Nothing else in the commit.

5. Comment the fix with what it fixes and why it is needed.

6. `bun run compile` must pass. Any new or changed TypeScript function gets a unit test under that package's `src/test`, watched failing before it passes.

7. Commit the fix on its own. Never with `--no-verify`.

8. Go back to step 1.

## Unit Tests

- A unit test for every TypeScript function a fix creates or changes, watched failing before the fix and passing after. Which ones cannot be known in advance.
- No test for shell changes: the repo bans `*.test.sh`.

## Smoke Tests

- `bun run test:parallel -- --scripts "<A> <B>"` to confirm the fixed pair comes back `ok`.
- The final full `bun run test:parallel` is the end-to-end proof.

## Verify

- `bun run compile` passes.
- `bun run test:parallel` exits 0 in a single run with every combination `ok`.

## Notes

- Exit codes: 0 clean, 1 interference, 2 bad usage, 3 too many Bun crashes, 4 the emulator pool degraded, 5 a script failed on its own so its pairs prove nothing.

## Outcome

Done. `bun run test:parallel` came back clean in a single run on 2026-08-12: all ten combinations of `test`, `test:cli`, `test:electron` and `test:and` reported `ok`, every script clean alone, no inconclusive combination and no Bun crash. Session `tmp/parallel-check/20260812-105148`. `test:ios` was left out because this is not macOS, which leaves 5 of the 15 combinations unchecked, and the run says so itself.

Two runs were needed and each produced one commit.

Run 1 (`tmp/parallel-check/20260812-085928`) found one conflict, `test` with `test:and`, and it was not a shared file, port or directory. `process_control_verify_job_control` proves once per shell that a background job gets a process group of its own, using a `sleep 1 &` probe whose group it then reads through `ps`. Under the load of a second suite the read outlived the probe, `ps` printed nothing for a pid that had gone, and the empty answer was read as proof that job control was broken, so every launch in that shell refused. The probe now sleeps 60 seconds and is still killed as soon as its group has been read. Commit 26d026f2. Registered as `JOB-CONTROL-PROBE-READ-AFTER-EXIT`.

The second commit came from the pre-commit hook rather than from the check. The hook refused the first commit with `test:lan-share:cli-desktop` test 4 failing on "CLI receiver did not start within timeout": the wait slept half a second per iteration while counting to 15, so it gave up after 7.5 seconds, and under ten concurrent suites the CLI had not printed its first line by then. It now counts seconds like every other loop in that file and waits `LAN_TIMEOUT`. Commit 3950fb13. Registered as `CLI-RECEIVER-DID-NOT-START-IN-TIME`.

One thing was seen and not fixed. A standalone run of the LAN share suite failed test 2 with the sender reporting no device found for its full 60 seconds and the desktop receiver giving up at the same time. It did not reproduce: the next run passed, as did the hook's run after it. It is not the known `SHARE-DB-REVIEW-STEP-NEVER-REACHED`, because that mode ends with a sender that heard a stranger, and this sender heard nothing. It is recorded unticked as `CLI-DESKTOP-SHARE-NO-DEVICE-FOUND` with the one candidate mechanism worth checking next time: same-host discovery depends on a unicast to `127.0.0.1:54321`, the socket sets `reuseAddr`, and a unicast reaches only one of several sockets bound to that port, so two senders at once would starve one of them. Nothing recorded what held the port when it failed, so that is a candidate and not a finding.

What this run does not show: one clean run per combination is not a rate. The check runs each combination once, so a conflict that appears on some runs and not others can pass through it, exactly as `UNIT-ENCRYPTION-TMP-DIR-SHARED` did. Both fixed modes above are load-dependent races rather than certainties, so their entries are ticked with that caveat rather than as 10x clean.
