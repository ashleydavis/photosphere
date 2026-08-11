# Climb the flaky-test ladder at twenty runs a rung

## Overview

Prove the four test suites are not flaky by climbing the `find-flakey-tests` ladder with a twenty-run streak required of each rung, and fix, one at a time, whatever the climb turns red. The ladder runs `bun run test`, then `bun run test:cli`, then `bun run test:electron`, then `bun run test:and`, cheapest first, and stops at the first rung that fails. Every failure is treated as a real defect in that one test and is fixed at its cause, with the smallest change that removes the cause and nothing else committed alongside it. After each fix the climb restarts, because a streak with a failure in it is not a streak. The work is done when the ladder reports twenty consecutive green runs of all four rungs on one tree.

This is the ten-run plan raised to twenty after it passed. The ten-run climb is recorded under "Previous outcome" at the end, along with the three fixes it produced and the modes it left open. Twenty runs a rung is roughly seven hours of climbing when nothing fails, so expect it to take considerably longer than the ten-run pass did.

## Issues

<empty>

## Steps

1. **Check the emulator pool at the moment of starting, not before.** Run `bun run emu:and:pool:status` and read the exit code: 0 means at least one pool emulator is on the LAN bridge, 1 means none is. The Android rung cannot run without it. If the pool is down, still start the climb, because the first three rungs do not touch a device, and record in this plan's Notes that the pool must be up before the ladder reaches `test:and`.

2. **Start the climb and capture the output.** Run `bun run find-flakey-tests -- --ladder --target 20`, writing stdout to a log file under the session scratchpad so the whole thing is readable afterwards. Start it with `setsid` so it is its own session: started as an ordinary background task it is swept up whenever background tasks are cleared, which killed four climbs in the ten-run pass, each within a minute of starting and each looking like a failure when nothing had failed. Record its pid. Each rung's own per-run logs are written under `tmp/find-flakey-tests/<timestamp>/<NN>-<suite>/` regardless. Do not pass `--script`, `--test` or `--command`, which cannot be combined with `--ladder`.

3. **On a green climb, stop.** The last lines of stdout name the session directory. Confirm the script exited 0 and that every rung reported twenty green runs, then report the session path and finish. Exit 1 is a test failure, 2 is bad usage, 3 is too many consecutive Bun crashes, and 4 is an Android pool that stopped being healthy and did not come back. Only 0 counts as done, and 3 and 4 mean the result is meaningless rather than red, so the climb restarts from the same rung with `--resume` for the greens already banked.

4. **On a failure, read the report before touching any code.** `tmp/find-flakey-tests/<timestamp>/report.txt` names the failing rung, the failing lane and test, the tail of that run's output, the snapshotted suite-side logs from the failing run, and the machine state at the time (memory, attached devices, recent kernel out-of-memory kills). Read the failing run's own log in the rung subdirectory as well as the report. Identify the one test that failed and the earliest error line in it, never a downstream "not ready" or timeout that follows from it.

5. **Match the failure against the registry before diagnosing it fresh.** Compare the earliest error line, with ports, PIDs, timestamps, paths, ids, durations and hashes stripped out, against the patterns in `docs/flaky-tests-registry.md`. A match on a ticked entry means that fix is disproven: untick the box, append the recurrence with today's date and the session directory, and remove the failed fix commit from the entry, per the registry's own rules. A match on an unticked entry means the mode is known and unfixed, and its recorded root cause is the starting point rather than a fresh investigation.

6. **Check the `ci-green` worktree for a fix that already exists.** The `ci-green` branch is checked out in the worktree at `.claude/worktrees/ci-green` and carries flaky fixes that this branch may not have. Before diagnosing anything, look there for a fix to the same failure: search that branch's history for the failing test's file or name (`git log --oneline ci-green -- <path to the failing test>`), read `docs/flaky-tests-registry.md` on `ci-green` for an entry matching the pattern from step 5, and read any commit that looks like it addresses the same cause. If one is there, cherry-pick that commit onto this branch rather than writing a second fix for the same defect, confirm it applies cleanly and that the test it fixes passes, and skip steps 7 and 8 for this failure. If the cherry-pick conflicts or the commit carries unrelated changes as well, take only the part that fixes this failure and say in the commit message which `ci-green` commit it came from. If nothing there matches, carry on to step 7.

7. **Find the cause of that one test's failure, and state it from evidence.** Read the test and the code it drives. Where the cause is not visible from the logs already captured, reproduce it by looping that test alone: `bun run find-flakey-tests -- --script <suite> --test <filter>`, which passes the filter straight through to the suite, so a number, part of a name or a full directory name all work. A single test loops in seconds where the suite takes minutes. Do not proceed to a fix on an argument that has no evidence behind it: if the cause cannot be established, say so rather than changing code on a guess.

8. **Fix the cause with the smallest change that removes it.** Confine the change to the test or the code the cause is in. Do not tidy neighbouring code, do not rename anything, do not reformat, and do not fix a second thing noticed on the way, because everything committed alongside the fix has to be justified by the failure and none of that is. Widening a timeout is a fix only when the evidence says the wait was genuinely too short for the work; when the evidence says the test raced something, the fix waits for the thing rather than for longer. If the cause is contention on a machine-wide name (a fixed port, a fixed path, a fixed lock, a fixed device), the fix allocates the resource per run: a free port, or `scripts/lib/allocate-test-temp-dir.sh` for a directory.

9. **Prove the fix goes red without it.** Revert the fix in the working tree, or break the value it asserts, and watch the looped single test fail; then restore it and watch it pass. A fix that has only ever been seen passing has not been shown to fix anything. Where the failure is rare enough that a red run cannot be produced on demand, say so plainly in the commit message and in the registry entry rather than claiming a proof that was not obtained.

10. **Meet the repository's own requirements for the changed code.** `bun run compile` must pass. Any new or changed TypeScript function gets a unit test under that package's `src/test`, watched failing before it passes. A changed shell script gets no test, by the repo rule that bans `*.test.sh`; the proof for shell is the suite it drives running green. `bun run test:everything` is the canonical check of a change and is what the commit hook runs.

11. **Record the mode in `docs/flaky-tests-registry.md`.** A new mode gets a new entry carrying id, an unticked Fixed box, the suite and command it was seen in, a pattern that is a regex over invariant text only, the fix commit, the first-seen date with the session directory, recurrences, the root cause, and the evidence. Tick the box and fill in the fix commit only once the fix has landed and a repeated run of that suite has passed clean, which the restarted ladder in step 12 provides.

12. **Commit the fix on its own.** One commit per flaky fix, containing the fix, its test, and the registry entry, and nothing else. Check `git status` and `git diff HEAD` first, since the human stages work as they review it and the staging area changes without warning. Never commit with verification disabled: `--no-verify`, `-n`, and every other way of skipping the hook are banned outright, and a hook refusal is reported to the human, not worked around.

13. **Restart the climb from the bottom.** After each committed fix, start `bun run find-flakey-tests -- --ladder --target 20` again from the first rung rather than resuming above the failed one. `--resume` is only sound when the tree has not changed since those greens were banked, and a fix changes the tree, so the rungs below have to be re-proven on it. Repeat steps 2 through 12 until a climb comes back green.

14. **Report each cycle as it happens.** After every failure, say which test failed, what the cause was, what the fix changed, and what evidence proved it. After the final green climb, report the session directory and the number of fixes the climb required.

## Unit Tests

- No unit test is written for the ladder itself. `find-flakey-tests.sh` is shell, and the repo bans `*.test.sh`; its behaviour is verified by running it.
- Every TypeScript function a fix creates or changes gets a unit test in that package's `src/test` directory, watched failing before the fix and passing after. Which functions those are cannot be listed in advance, because they depend on what the climb finds.
- Where a fix corrects a race in application code rather than in a test, the unit test drives the function directly with the state the logs recorded, so the defect is pinned by something that runs in milliseconds rather than only by the smoke test that found it.

## Smoke Tests

- The failing test itself is the end-to-end cover for its own fix, looped with `bun run find-flakey-tests -- --script <suite> --test <filter>` to a streak, not run once.
- No new smoke test is added for a flaky fix unless the fix exposed behaviour that no existing test covers. The suites already exercise these paths; the defect is that they do so unreliably.
- `bun run test:parallel` (`scripts/check-parallel-tests.sh`) is the check to run when a failure looks like contention rather than flakiness, since it runs each suite alone and then every pair together, self-pairs included, and reports only what fails in company. A verdict of `interference` belongs in the parallel-only section of the registry; `inconclusive` means the suite is unreliable alone and belongs back on the ladder first.

## Verify

- `bun run compile` passes.
- `bun run test` passes, including every unit test added by a fix.
- `bun run test:everything -- --force` passes.
- `bun run find-flakey-tests -- --ladder --target 20` exits 0 with twenty consecutive green runs recorded for `test`, `test:cli`, `test:electron` and `test:and`, on the tree that carries every fix.
- `docs/flaky-tests-registry.md` has an entry for every mode the climb found, each with its fix commit recorded and its Fixed box ticked by the final green climb.

## Notes

- The default rungs leave out `test:ios`, which can never pass on Linux. On macOS the climb is `--ladder "test test:cli test:electron test:and test:ios"`.
- A sick Android emulator pool pauses the loop rather than failing it: the loop says the pool is sick and waits, keeping the streak, and gives up only after `DEVICE_WAIT_SECONDS` or after `DEVICE_FAILURE_RETRIES` red runs in a row. That pause only applies to commands that actually drive the emulators, so the first three rungs are unaffected.
- A Bun SIGSEGV or SIGILL is retried rather than counted, up to `BUN_CRASH_RETRIES` in a row, and every crash is still reported in the summary. A crash is not a flaky test and must not be fixed as one.
- Per-test temporary directories accumulate, one per test per run, and nothing removes them. That is deliberate. The session prints the count at the end, and a long climb will push it up.
- Twenty runs a rung is still well short of the script's default of a hundred. A mode that fails one run in fifty will more often than not pass a twenty-run streak, so a green climb at this target says the suites are cleaner than ten runs proved, not that they are clean.
- The ten-run climb that passed ran alone on a quiet machine, and every mobile LAN-share failure in that session needed a busy one. If this climb is also to be run alone, its mobile rung carries the same weakness. Running something else alongside it would test more, at the cost of not knowing whether a failure was the suite or the company it was keeping.
- The first attempt at this climb was killed during rung 1 after one green run of `bun run test`, so it produced no findings.

## Previous outcome, at ten runs a rung

Done on 2026-08-11, then reinstated at twenty. The ladder came back green on the tree carrying all three fixes: session `tmp/find-flakey-tests/20260811-140520`, `every rung of the ladder is clean, 10 consecutive green runs each`, 3h 28m total (`test` 18m 12s, `test:cli` 31m 04s, `test:electron` 1h 04m, `test:and` 1h 34m).

Three fixes, one commit each, each landed through a full green pre-commit hook and none with verification disabled:

- `97c1b199` Stopped a live S3 write lock being broken as a corrupt one. Found by rung `test:cli` failing on run 2 of the first climb. `CloudStorage.acquireWriteLock` treated a lock it could not read back as corrupt, deleted it, and took it with an unconditional write, putting three processes in the critical section at once and losing one writer's records. Registry entry `S3-LOCK-BROKEN-WHILE-HELD`, now ticked.
- `580c2d48` Made a receive that is never reached say so. The receive dialog's one give-up path set on-screen text and logged nothing, so a mobile LAN-share failure left no trace and could not be diagnosed. It logs how long the wait lasted, which is what told the next two failures apart.
- `60272a8e` Stopped a cancelled receive taking the next receive with it. Found by rung `test:and` failing on run 2 of the second climb, and readable only because of the log line above: both receives gave up in under a second, so the second was cancelled rather than unserved. `cancelShareReceive` now waits for the cancelled receive's task to settle before returning. Registry entry `MOBILE-LAN-RECEIVER-NEVER-DISCOVERED`.

Left unfixed, recorded rather than guessed at:

- The full-timeout presentation of `MOBILE-LAN-RECEIVER-NEVER-DISCOVERED`, where the receiver waits out its whole 60 seconds and is never reached. Cause not established. The strongest lead is the emulator pool losing the LAN bridge under load, seen directly during this session's mobile rung: three emulators lost `192.168.55.1` within 42 seconds and four of five later vanished from `adb`, with no out-of-memory kills and 44GB free.
- Bun crashes: `SIGILL` twice during `psi verify` and a segfault once in `test:cli:encrypted`. A crash is not a flaky test. The ladder retries them; the commit hook does not, so they can refuse a commit.
- `find-flakey-tests --test` sends its filter to the wrong command for `test`, `test:cli` and `test:electron`, because those package.json scripts end in `&& what-changed baseline capture`. The suite runs in full and then fails on the stray argument, which reads as a test failure. `bun run tc -- <n>` works; `--test` works for `test:and`, whose script has no trailing command.

Caveats worth carrying forward, beyond the ten-runs-is-a-weak-claim note above: this climb ran alone on a quiet machine, and every mobile LAN-share failure this session needed a busy one, so the mobile rung's ten greens are the weakest of the four.
