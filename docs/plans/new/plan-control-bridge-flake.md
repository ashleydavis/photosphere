# Find the root cause of the control-bridge flake

## Overview

The mobile smoke harness intermittently fails a test before it has run anything, with `Control bridge did not start on port N within 40s`. It hit five different tests in one day (`13-edit-s3-credentials`, `17-news-notifications`, `11-edit-encryption-key`, `2-create-database`, `31-create-database-no-collision`), always under the full parallel test set, never twice the same test. It is already in `docs/flaky-tests-registry.md` as `BRIDGE-START-BIND`, ticked as fixed, with its Fix commit recorded as "uncommitted working change" — so that fix never landed and the mode is live. The message is also wrong: the bridge demonstrably starts. `wait_for_bridge` in `apps/smoke-tests/lib/common.sh` was changed to tell "exited" apart from "still running but unreachable", and the most recent failure reported the second: the bridge process was alive for the whole 40 seconds and `bridge.log` held its own `Control bridge listening on port 39667` line. So the process starts, binds, logs, stays up, and never answers a single one of 200 HTTP polls. This plan is diagnosis, not repair. It exists because four separate investigations have already been spent guessing, and the one thing that would settle it — knowing why the HTTP request failed — is not recorded anywhere. Do not propose a fix until a step here has produced evidence naming the cause.

## Issues

## What is known

Everything here was observed directly, in one day, on one Linux machine. None of it is inference unless it says so.

### The five occurrences

Every one has the identical shape. The harness prints the bridge's PID and port, the bridge writes its own listening line to `bridge.log`, and then forty seconds pass with no answer.

| Test | PID | Port | Test took | Second failure line |
| --- | --- | --- | --- | --- |
| `13-edit-s3-credentials` | 3724113 | 35617 | 42s | `curl failed (exit 56) posting to quit` |
| `17-news-notifications` | 698693 | 32773 | 43s | `curl failed (exit 56) posting to quit` |
| `11-edit-encryption-key` | 3399578 | 34013 | 43s | `curl failed (exit 56) posting to quit` |
| `2-create-database` | 67612 | 40615 | 45s | `curl failed (exit 1) posting to quit` |
| `31-create-database-no-collision` | 1919516 | 39667 | 43s | `curl failed (exit 1) posting to quit` |

Five different tests, five different ports, five different PIDs, never the same test twice. The tests themselves have nothing in common: two create a database, one edits S3 credentials, one edits an encryption key, one is about news notifications. Whatever this is, it is not in the test.

The test-run log for a failure is four lines and contains nothing else, because the failure happens before the test body starts:

```
=== TEST 2: create-database ===
[INFO] Control bridge started (PID 67612, port 40615)
[FAIL] Control bridge did not start on port 40615 within 40s
[FAIL] curl failed (exit 1) posting to quit:
000
```

The last occurrence, after `wait_for_bridge` was changed to tell the two cases apart, reported:

```
[FAIL] The control bridge (PID 1919516) is still running but did not answer on port 39667 within 40s (last curl exit 0).
[FAIL] What the bridge printed:
  Control bridge listening on port 39667
```

That `last curl exit 0` is a bug, not data. See step 1.

### What the artefacts show

Each failing run leaves a directory under `apps/smoke-tests/tests/<test>/tmp/run-<suite-pid>/` containing `bridge.log`, `bridge.pid`, `bridge.port`, `.log-cursor` and `test-run.log`. In every one of the five:

- `bridge.log` contains exactly one line: `Control bridge listening on port <N>`, and nothing else. No error, no stack, no crash output. Bun prints a panic to stderr and `bridge.log` captures both streams, so a Bun crash would be visible here and is not.
- `bridge.port` contains the same port the harness reported. That file is written by `control-bridge-main.ts` only after `runBridgeFromEnv()` resolves, which is after `httpServer.listen()` has called back. So the socket was bound.
- `bridge.log`'s mtime is at the very start of the test, and the directory mtime is 40-odd seconds later. The bridge logged listening immediately and then nothing happened for the whole timeout.
- There is no `app.log`, because the app is never launched: `start_app` calls `wait_for_bridge` before `${PLATFORM}_launch`.

### What the code does

- `apps/smoke-tests/lib/common.sh`, `start_app`: launches `bun lib/control-bridge-main.ts` in the background with `PHOTOSPHERE_TEST_PORT=0`, redirects both streams to `bridge.log`, `disown`s it, writes `$!` to `bridge.pid`, waits for `bridge.port` to appear via `wait_for_bridge_port`, logs `Control bridge started`, then calls `wait_for_bridge`.
- `apps/smoke-tests/lib/control-bridge.ts`, `ControlBridge.start()`: `httpServer.listen(0, "0.0.0.0", cb)`. Port 0 means the OS assigns, so two concurrent bridges cannot collide. IPv4 only.
- `apps/smoke-tests/lib/control-bridge-main.ts`: after `start()` resolves, writes `bridge.port` then logs the listening line. Both therefore happen strictly after the socket is listening.
- `apps/smoke-tests/lib/common.sh`, `wait_for_bridge`: polls `curl -s -o /dev/null "http://localhost:$port/ready"` every `POLL_INTERVAL_SECONDS` (0.2) for `DEFAULT_BRIDGE_TIMEOUT` (40) seconds, so **200 attempts**.
- `control-bridge.ts` `/ready` returns 200 when the app has connected and **503 when it has not**. The probe has no `--fail`, so curl exits 0 on a 503. **Any HTTP answer at all satisfies the wait.**

That last point is the important one. The failure is not the app being slow to connect, and it is not readiness. Two hundred consecutive attempts failed to get any HTTP response whatsoever, which is a connection-level failure against a socket that the process had already bound and was still holding.

### What has been ruled out, with the evidence

- **The bridge process dying.** The last occurrence checked `kill -0` on the recorded PID on every poll and it was alive throughout.
- **A port collision.** The bridge binds port 0 and the harness reads the assigned port back from `bridge.port`.
- **A Bun crash.** `bridge.log` would hold the panic. It holds one line.
- **The app being slow.** The app is never started, and a 503 would have satisfied the probe anyway.
- **Anything test-specific.** Five unrelated tests.

### What has not been ruled out

- Whether `curl` reached the socket at all. This is the single most valuable unknown and is what step 1 unblocks.
- Whether `localhost` resolved to `::1` first while the bridge is IPv4-only, and the fallback failed or was too slow under load.
- Whether the listen backlog filled, or the process was alive but not accepting.
- Whether `curl` itself failed to start under process or memory pressure, which would look identical from the harness's side and has nothing to do with the bridge.
- Whether the machine's load is the whole story rather than a contributing factor.

### Reproducing it

It only ever appeared under the full parallel set. It has never been seen with a single test, a single suite, or the Android suite alone.

```
for i in $(seq 1 12); do
  echo "=== run $i ==="
  bun run tev > /tmp/bridge-hunt-$i.log 2>&1 || { echo "FAILED on run $i"; break; }
done
```

- Each run is about three and a half minutes, so twelve runs is roughly forty-five minutes.
- The emulator pool must be up first. `bun run test:and` refuses immediately without it, which is a different failure and not this one.
- Observed rate was roughly **one run in six**, but that is five occurrences across a day rather than a measured rate, and the clustering matters: see the load note below.
- The evidence lives in `apps/smoke-tests/tests/<test>/tmp/run-*/`. That directory is per run and is not cleaned between runs, so a failure's artefacts survive.
- Grep for it with `Control bridge did not start|did not answer on port`.

### The load it happened under

Every occurrence was during `bun run test:everything`: six scripts at once, across six Android emulators, alongside an Electron suite spawning many Chromium processes under `xvfb-run`, a Gradle build, and a TypeScript compile.

On that day the machine was also carrying a separate defect, since fixed: the Electron smoke suite leaked its whole app process tree and an X server on every run, and 170 stale Electron processes had accumulated across three worktrees holding 8.8GB, with swap at 64GB of 65. `systemd-oomd` killed 354 processes in one go at one point, taking the emulator pool with it.

After that leak was fixed, eleven consecutive full runs passed, then one failed out of the next six. So the leak was not the whole story, but the memory pressure it caused may well have made the mode more likely. Record free memory, swap and load average alongside the other evidence so this can be settled rather than argued.

## Steps

1. **Fix the bug that makes the existing diagnostic useless.** In `wait_for_bridge` in `apps/smoke-tests/lib/common.sh`, `curl_status=$?` is read on the line after `fi`. After an `if` whose condition failed and which has no `else`, `$?` is the status of the `if` compound command, which is 0, not curl's. Every failure therefore reports `last curl exit 0`, which is impossible and tells you nothing. Capture curl's status from the condition itself, so the reported number is the real one. Nothing else in that function changes. `bash -n` on the file must pass, and `bash apps/smoke-tests/timeout.test.sh` and `bash apps/smoke-tests/runner.test.sh` must still pass, since both source this file.

2. **Record what the failing curl actually said.** Still in `wait_for_bridge`, on the final failure path only, re-run the probe once with stderr captured rather than discarded (drop the `-s` and the `2>/dev/null`) and print curl's own message alongside its exit code. The polling loop keeps discarding output; only the one diagnostic attempt after the loop gives up is verbose. curl's exit codes separate the candidate causes cleanly and are the single most valuable thing to capture: 7 is connection refused, 28 is a timeout, 6 or 5 is a name that would not resolve, 56 is a receive failure, 52 is an empty reply. Each points at a different fault.

3. **Record the socket state at the moment of failure.** On the same failure path, capture and print whether anything is listening on that port and what the connection state is, using `ss -ltnp` filtered to the port where `ss` exists and falling back to `netstat -ltnp` where it does not, plus `lsof -i` on the port if available. State which tool produced the output. This distinguishes "the socket is gone", "the socket is listening but the backlog is full" and "the socket is listening and idle", which are three different bugs. Also print the listen address family, because the bridge binds `0.0.0.0` (IPv4 only) while the probe asks for `localhost`, which can resolve to `::1` first.

4. **Record what the bridge process is doing.** On the same failure path, print the process state from `ps -o pid,stat,wchan,etime,rss -p <pid>` and, on Linux where it exists, the contents of `/proc/<pid>/status` filtered to `State` and `Threads`, plus the count of open descriptors from `/proc/<pid>/fd`. A process in `D` state, or one against a descriptor limit, is a different fault from one sitting idle in `S`. Guard every read so a missing `/proc` on macOS degrades to a printed note rather than an error.

5. **Make the probe's own assumptions visible.** Add a single line to the failure output recording what `localhost` resolved to for this attempt, via `getent hosts localhost` on Linux or `dscacheutil -q host -a name localhost` on macOS, falling back to a printed note where neither exists. The bridge binds IPv4 only; if the probe is reaching for `::1` and the fallback is what is failing under load, this is where that shows.

6. **Reproduce it.** Run the full parallel set repeatedly until the failure fires, capturing each run's output to its own file, stopping at the first failure so the evidence is not buried. Roughly one run in six failed on the day it was observed, and each run takes about three and a half minutes, so budget for a dozen runs before concluding it will not reproduce. Do not run the emulator or bridge in isolation for this: every observed occurrence was under the full set, and a lighter load may never trigger it. If twelve runs pass, say so plainly and stop; a mode that will not reproduce cannot be diagnosed, and guessing is what this plan exists to avoid.

7. **Name the cause from the evidence, or say it is still unknown.** Read the captured curl exit code, socket state, process state and resolution result together and state which of these it is: the socket was gone; the socket was listening but the process was not accepting; the process was blocked; the probe never reached the socket at all; or something else the evidence shows. Write the finding into `docs/flaky-tests-registry.md` under `BRIDGE-START-BIND`, untick its Fixed box, remove the Fix commit line that names an uncommitted change that never landed, and append this occurrence to Recurrences with its date and the evidence. Do not write a fix into that entry that has not been made.

8. **Only now, fix it.** With the cause named, make the smallest change that addresses it, in `apps/smoke-tests/lib/control-bridge.ts` or `apps/smoke-tests/lib/common.sh` depending on where the fault is. Add a unit test for any function changed. Then re-run the loop from step 6 and require ten consecutive clean runs before claiming it is fixed, and say plainly that ten runs is evidence rather than proof for a mode that appeared once in six.

## Unit Tests

- `wait_for_bridge` reports a bridge that exited, printing what the bridge logged, and does so immediately rather than after the full timeout.
- `wait_for_bridge` reports a bridge that is still running but never answers, and reports curl's real exit code rather than 0. This is the assertion that would have caught the step 1 bug.
- `wait_for_bridge` returns success when the probe gets any HTTP answer, including a 503, since `/ready` returns 503 until the app connects and the harness deliberately treats that as the bridge being up.
- `wait_for_bridge` returns success promptly rather than polling for the full timeout when the bridge answers on the first attempt.
- Any function added or changed in step 8 gets its own test.

These go in a new `apps/smoke-tests/wait-for-bridge.test.sh`, following `apps/smoke-tests/timeout.test.sh`: source `lib/common.sh`, drive it with a stub `curl` on a PATH holding nothing else, and use a real short-lived background process as the bridge pid so the liveness check is exercised against a real process rather than a fake one.

## Smoke Tests

- The loop in step 6 is the end-to-end check, and it is the only one that exercises the real fault. Capture it as a short script under `apps/smoke-tests/` that runs the full set N times, stops at the first failure, and keeps every run's log, so the next person chasing this does not have to reinvent it.
- After step 8, that same script run ten times clean is the acceptance check.
- No new test may start, stop or restart an emulator. `apps/android-frontend/CLAUDE.md` is explicit that the emulator and bridge are the human's to manage, and every step here is either a stub or a read.

## Verify

- `bash -n apps/smoke-tests/lib/common.sh` passes.
- `bash apps/smoke-tests/wait-for-bridge.test.sh` passes.
- `bash apps/smoke-tests/timeout.test.sh`, `bash apps/smoke-tests/runner.test.sh` and `bash apps/smoke-tests/android-lock.test.sh` all still pass, proving the change to `common.sh` broke nothing that sources it.
- `bun run compile` clean and `bun run test` passing.
- A failure captured during step 6 shows a curl exit code other than 0, socket state, and process state. If the reported curl code is still 0, step 1 was not actually fixed.
- `docs/flaky-tests-registry.md` has `BRIDGE-START-BIND` unticked, its never-landed Fix commit removed, and this occurrence recorded.
- `git diff` touches only `apps/smoke-tests/lib/common.sh`, the new test script, the new loop script, `docs/flaky-tests-registry.md`, and whatever step 8 required.

## Notes

- **Do not modify `.githooks/pre-commit`, `.githooks/pre-push`, `scripts/install-hooks.sh` or `scripts/test-everything-parallel.sh`.** `CLAUDE.md` freezes those four. The loop in step 6 calls `bun run test:everything`; it does not change it.
- **What is already ruled out.** The bridge process is not dying: the most recent failure reported it alive for the full 40 seconds with its own listening line in `bridge.log`. Port collision is not it either: the bridge binds port 0 and the OS assigns, and the harness reads the actual port back from `bridge.port`, which is written after `listen` resolves.
- **Readiness is not it.** `/ready` returns 503 until the app connects, and the probe is `curl -s -o /dev/null` with no `--fail`, which treats 503 as success. So any HTTP answer at all satisfies the wait, and 200 consecutive failures means nothing answered at the connection level.
- **The load matters and may be the whole story.** Every occurrence was under the full parallel set: six suites at once, six emulators, an Electron suite and a Gradle build. On the day it was observed the machine was also carrying 170 leaked Electron processes holding 8.8GB with swap at 64GB of 65, and `systemd-oomd` killed 354 processes at one point. The leak has since been fixed and the mode has been rarer, which is suggestive and not evidence. Record memory and load alongside the other evidence in step 6 so this can be confirmed or dismissed rather than argued about.
- **A related mode to keep separate.** Bun itself segfaulted (`SIGILL`, exit 132) in three different CLI tests on the same day, printing "Bun has crashed. This indicates a bug in Bun, not your code." That is a different failure with a different signature and does not belong in this entry, but if step 6's evidence shows the bridge process dying rather than hanging, the two may share a cause and that is worth noting.
- **Stub-driven shell tests are contentious in this repository.** An earlier attempt to test the git hooks this way was rejected, on the grounds that faking `bun` proves the branching rather than the gate. The tests proposed here are narrower: they test one shell function's decision logic against a stub `curl` and a real process, which is the same shape as the existing `timeout.test.sh`. Confirm this is acceptable before writing them rather than assuming, and if it is not, do steps 1 to 7 without them, since diagnosis is the point and the tests are not what produces the answer.
- **Resist fixing before step 7.** Four investigations have already been spent on this, three of them ending in a confident wrong answer: that it was the leaked Electron processes, that it was cross-suite LAN interference, and that it was a stale `ANDROID_HOME`. The evidence steps exist because guessing has a track record here.
