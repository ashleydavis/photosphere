# Diagnose the 8-share-database Electron smoke test flake

## Overview

`8-share-database` in the Electron smoke suite fails intermittently. It failed once during a full `bun run smoke` on 2026-07-31 and passed on an immediate standalone re-run, so it is flaky rather than broken. This plan is a root cause investigation, not a fix design: the job is to find what actually causes the failure, prove it with recorded evidence committed to the repository, and only then make the smallest change that removes the cause. The proof that the change worked is 100 consecutive green runs. If any run in the 100 fails, the change is wrong: revert it and go back to investigating.

The work is deliberately narrow. It touches the Electron smoke test harness and nothing else. It adds no test-only scaffolding to the application. It does not tidy, refactor, harden, or improve anything that is not the proven cause of this failure.

## Issues

## What is already known

This section is the starting evidence. It is not a conclusion, and steps below must re-derive and prove anything used in the final root cause claim.

### The observed failure, verbatim

Captured from `bun run smoke` on 2026-07-31, from `apps/desktop/smoke-tests/8-share-database/tmp/test-run.log` as reprinted by the runner. Colour codes stripped. The original `tmp/` has since been overwritten by a later run, so this transcript is the only surviving copy and must be preserved.

```
============================================================================
=== TEST 8: share-database ===
============================================================================
[INFO] Running headless (xvfb-run). Set SHOW_UI=1 to show the window.
[INFO] App started (PID 3095144, port 35237)
[INFO] Waiting for app to be ready on port 35237...
[INFO] App is ready
[INFO] Waiting for log pattern: Databases page loaded (after line 0)
[INFO] Found: Databases page loaded (line 21)
[INFO] Waiting for pairing code...
[INFO] Pairing code: 9787
[INFO] Running headless (xvfb-run). Set SHOW_UI=1 to show the window.
[INFO] App started (PID 3095484, port 38121)
[INFO] Waiting for app to be ready on port 38121...
[FAIL] Timed out waiting for app to be ready after 120s (attempt 1 of 2)
[INFO] Relaunching app and retrying...
[INFO] Running headless (xvfb-run). Set SHOW_UI=1 to show the window.
[INFO] App started (PID 3109665, port 44475)
[INFO] App is ready
[FAIL] curl failed (exit 52) posting to navigate: 
[INFO] Waiting for log pattern: Databases page loaded (after line 0)
[FAIL] Timed out waiting for log pattern: Databases page loaded
[FAIL] Last 30 lines of app.log:
  [EVENT] Single instance lock acquired (pid=3109781, packaged=false)
  [3109781:0731/082053.003842:ERROR:dbus/object_proxy.cc:573] Failed to call method: org.freedesktop.systemd1.Manager.StartTransientUnit: object_path= /org/freedesktop/systemd1: org.freedesktop.systemd1.UnitExists: Unit app-org.chromium.Chromium-3109781.scope was already loaded or has a fragment file.
  [Main] Photosphere Desktop starting...
  [EVENT] Instance started (pid=3109781, packaged=false)
  REST API utility process spawned
  [REST API Worker] Asset server running on http://localhost:39743
  [REST API Worker] Asset server initialized in utility process
  REST API initialized in utility process on port 39743
  MCP utility process spawned
  MCP server initialized in utility process on port 41161
  Worker pool initialized
  [EVENT] Main window created
  Test control server listening on port 44475
  [Renderer] Form factor: desktop (viewport width 960px, breakpoint 768px)
  [Renderer] Form factor: desktop (viewport width 960px, breakpoint 768px)
  Sync gate set to true
  Sync debounce triggered
  Sync gate set to true
  Sync debounce triggered
---------- end 8-share-database ----------
```

### What the transcript establishes on its face

- The sender instance started on port 35237 and worked. The pairing code was read successfully. The first half of the test is not implicated.
- The receiver instance started on port 38121 and never answered `GET /ready` within 120 seconds.
- `wait_for_ready` in `apps/desktop/smoke-tests/lib/common.sh` then took its designed recovery path: it killed the instance, relaunched it, and the relaunch came up on port **44475** and answered `/ready`.
- The relaunched app is healthy in its own log: it acquired the single instance lock, created its window, started its REST API on 39743, its MCP server on 41161, and logged `Test control server listening on port 44475`.
- The very next action, `send_command ... navigate`, failed with **curl exit 52**, which is `Empty reply from server`: a TCP connection was established and then closed without an HTTP response. It is not exit 7 (connection refused) and not exit 28 (timeout).
- Because `send_command` reports failure with `return 1` rather than `exit`, the test continued, and `wait_for_log` then failed waiting for `Databases page loaded` that could never appear.

### The leading hypothesis, which must be proven or discarded

`start_app` publishes the port it launched on in the global `APP_PORT`. `wait_for_ready` relaunches on failure by calling `start_app` again, which **reassigns `APP_PORT` to the new port**, and its own polling loop uses `$APP_PORT` rather than its `<port>` argument (the function's comment says so explicitly: "The `<port>` argument is accepted for call compatibility but the live port is always APP_PORT").

`apps/desktop/smoke-tests/8-share-database/test.sh` snapshots the port into its own variable **before** calling `wait_for_ready`:

```
start_app "$TMP_DIR/receiver" 960
RECEIVER_PORT="$APP_PORT"
wait_for_ready "$RECEIVER_PORT"
send_command "$RECEIVER_PORT" navigate '{"page":"databases"}'
```

If the relaunch fires, `APP_PORT` becomes 44475 but `RECEIVER_PORT` stays 38121, so every subsequent command in the test is posted to the port of the instance that was just killed. That matches the transcript exactly: ready succeeds (on 44475), the next command fails (on 38121), and the log wait then times out.

A grep over `apps/desktop/smoke-tests/*/test.sh` shows that **only tests 7 and 8 snapshot `APP_PORT` into a local variable**. Every other test passes `$APP_PORT` directly at each call site, so a relaunch is transparent to them. Tests 7 and 8 are the two that drive two app instances, and 8 is the one that failed.

Two things this hypothesis does **not** explain and which the investigation must still settle:

1. **Why did the first receiver launch never reach `/ready` in 120 seconds?** The relaunch path exists because this is a known occasional wedge, but it has not been characterised. It is the trigger; the stale port would be the reason the trigger becomes a test failure.
2. **Why curl exit 52 and not exit 7?** If port 38121 were simply free after the instance died, curl would report connection refused. Exit 52 means something accepted the connection. Candidates worth checking: the killed instance's listener socket lingering, or the OS reassigning 38121 to another listener (the app also opens a REST API port and an MCP port per instance, and test 7 runs immediately before test 8).

## Steps

Every step runs from the repository root through `mise exec --`. No step may modify `.githooks/pre-commit`, `scripts/install-hooks.sh` or `scripts/test-everything-parallel.sh`, which are frozen by `CLAUDE.md`. No step may add anything to the application source that exists only to serve a test.

### 1. Create the evidence directory and preserve the observed failure

- Create directory `docs/investigations/electron-8-share-database-flake/`.
- Create `docs/investigations/electron-8-share-database-flake/README.md` with headings `Observed failure`, `Static analysis`, `Deterministic reproduction`, `Root cause`, `Ruled out`, and `Fix and proof`. Leave the sections after `Observed failure` empty for now; later steps fill them in.
- Create `docs/investigations/electron-8-share-database-flake/observed-failure.log` holding the verbatim transcript from the "The observed failure, verbatim" section above, exactly as written, with a first line recording that it came from `bun run smoke` on 2026-07-31 on Linux.
- Fill in the `Observed failure` section of the README with the bullet list from "What the transcript establishes on its face" above.
- This step produces no code. Nothing to compile or test.

### 2. Record the static analysis of the port variable lifetime

- Read `apps/desktop/smoke-tests/lib/common.sh` and record, in the `Static analysis` section of the evidence README, the exact line numbers and code for: where `start_app` assigns `APP_PORT`, `APP_TMP_DIR` and `APP_X_POS`; where `wait_for_ready` polls `$APP_PORT`; and where `wait_for_ready` calls `start_app` on the relaunch path.
- Read `apps/desktop/smoke-tests/8-share-database/test.sh` and `apps/desktop/smoke-tests/7-share-secret/test.sh` and record the line numbers where each snapshots `APP_PORT`.
- Run `grep -n "APP_PORT" apps/desktop/smoke-tests/*/test.sh` and record the full output in the README, so the claim that only tests 7 and 8 snapshot the port is evidence rather than assertion.
- Write a short trace in the README stepping through the transcript's port numbers against those line numbers, showing which variable holds which value at each point.

### 3. Build a deterministic reproduction of the relaunch path

- Create `apps/desktop/smoke-tests/lib/relaunch-repro.sh` (executable, `set -uo pipefail`). It must reproduce the failure using only the real `common.sh` and the real Electron app, with no change to either.
- It sources `apps/desktop/smoke-tests/lib/common.sh`, sets `DESKTOP_DIR` to `apps/desktop`, creates a throwaway tmp directory under `apps/desktop/smoke-tests/lib/tmp/` (covered by the existing `tmp/` entry in `.gitignore`), and then:
  - Calls `start_app <tmp>` and snapshots `SNAPSHOT_PORT="$APP_PORT"`, mirroring what test 8 does.
  - Kills the launched instance with the library's own `_kill_app <tmp>`, so the next `/ready` poll cannot succeed and the relaunch path is forced deterministically.
  - Calls `wait_for_ready "$SNAPSHOT_PORT"`, which will spend `DEFAULT_WAIT_TIMEOUT` seconds failing and then relaunch.
  - After it returns, prints `SNAPSHOT_PORT`, `APP_PORT`, and whether they differ.
  - Calls `send_command "$SNAPSHOT_PORT" navigate '{"page":"databases"}'` and records the curl exit code, then calls `send_command "$APP_PORT" navigate '{"page":"databases"}'` and records that exit code.
  - Stops the app and removes its tmp directory.
- Set `DEFAULT_WAIT_TIMEOUT` low for this harness only, by exporting it before sourcing or overriding it after sourcing, so a run takes seconds rather than minutes. Record in the script's header comment that this is a diagnostic harness, not a smoke test, and that it is not part of any suite.
- The script must not be added to any `package.json` script and must not be discovered by `apps/desktop/smoke-tests.sh` (it lives under `lib/`, not in a numbered test directory, and is not named `test.sh`, so discovery already skips it; confirm that by running `bun run test:electron -- --list` or the equivalent and checking it does not appear).

### 4. Run the reproduction and record the result

- Run `apps/desktop/smoke-tests/lib/relaunch-repro.sh` at least three times, capturing output to `docs/investigations/electron-8-share-database-flake/reproduction.log` with `tee`.
- Record in the `Deterministic reproduction` section of the evidence README: the command, the observed `SNAPSHOT_PORT` and `APP_PORT` values, the curl exit code for the stale port, and the curl exit code for the live port.
- The reproduction is only accepted as proof if the stale-port command fails and the live-port command succeeds, in every run. If the stale-port command unexpectedly succeeds, the hypothesis is wrong: record that in the `Ruled out` section and return to step 2 with a new hypothesis.

### 5. Determine why the stale port gave exit 52 rather than exit 7

- Extend `relaunch-repro.sh` to run, immediately before the stale-port `send_command`, a listener check on the snapshot port and record its output: `ss -ltnp "sport = :$SNAPSHOT_PORT"` (fall back to `lsof -iTCP:$SNAPSHOT_PORT -sTCP:LISTEN` if `ss` is unavailable), and `curl -sv "http://localhost:$SNAPSHOT_PORT/ready"` captured with its exit code.
- Record in the README whether anything is listening on the stale port after the relaunch, and if so which process. Note explicitly whether curl reports exit 7, 52 or something else, and whether that differs from the production transcript.
- If nothing listens and the reproduction reports exit 7 while production reported exit 52, record that difference honestly in the `Ruled out` section: it means the stale port explains the failure cascade but the specific curl code came from a port that had been reused, which is a detail of that one run and not a second root cause. Do not chase it further.

### 6. Characterise the trigger without fixing it

- The relaunch only fires because the first receiver launch never reached `/ready`. Establish what is known about that and record it in the README under `Ruled out`, explicitly labelled as the trigger rather than the root cause.
- Check and record: whether `apps/desktop/smoke-tests/7-share-secret/` and `8-share-database` both carry `.sequential` markers (they do, so they run alone rather than in a parallel batch); whether test 7 leaves any process behind that could still be running when test 8 starts, by running `bun run test:electron -- 7` and then `ps -ef | grep -c electron` and recording the count before and after; and whether the `PER_TEST_TIMEOUT` of 300 seconds in `apps/desktop/smoke-tests.sh` can accommodate two 120 second `/ready` waits plus the test's own work (it cannot comfortably, and that is worth recording as an observation).
- **Do not fix the trigger.** The relaunch path exists precisely because the wedge is accepted as occasional. The scope of this plan is the failure that the relaunch causes, not the wedge itself. If the evidence shows the wedge is the real problem, stop and report that finding rather than widening the change.

### 7. Write the root cause statement

- Fill in the `Root cause` section of the evidence README with a single, falsifiable statement of the cause, each clause backed by a pointer to the recorded evidence (the transcript line, the code line number, or the reproduction log line).
- Add an entry to `docs/flaky-tests-registry.md` following the rules at the top of that file: an id, an unticked `Fixed` checkbox, the suite (`Electron smoke tests (bun run test:electron)`), a regex pattern over the invariant text of the failure with ports and PIDs normalised out, `Fix commit: none` for now, first seen `2026-07-31`, the root cause, and the evidence, linking to `docs/investigations/electron-8-share-database-flake/`.
- The registry pattern must match invariant text only. Match on the `curl failed \(exit \d+\) posting to navigate` line, since that is the earliest root error line in the cascade, not on the downstream `Timed out waiting for log pattern` symptom.

### 8. Make the minimal fix

- Derive the fix from the root cause statement written in step 7. **Do not decide the fix before that statement exists**, and do not implement anything from the hypothesis section above as though it were already proven.
- Constraints on whatever the fix turns out to be:
  - It changes the smallest number of lines that removes the proven cause, and nothing else.
  - It touches only the Electron smoke test harness (`apps/desktop/smoke-tests/`), unless the evidence proves the cause lies elsewhere, in which case stop and report before changing anything outside it.
  - It adds nothing to the application source.
  - It does not restructure, rename, extract, or otherwise improve code that is not the cause.
  - If the same cause is present in `apps/desktop/smoke-tests/7-share-secret/test.sh`, fix it there too, because that is the same defect and not a second one.
- Record the fix, as a diff, in the `Fix and proof` section of the evidence README.

### 9. Add a shell unit test for the fixed behaviour

- Create `apps/desktop/smoke-tests/lib/common.test.sh`, following the shape of the existing `apps/smoke-tests/runner.test.sh`: `set -uo pipefail`, a `check <description> <expected> <actual>` helper, a `mktemp -d` work directory with a cleanup trap, stub scripts rather than a real app, and a `fails` counter that decides the exit status.
- It must source `apps/desktop/smoke-tests/lib/common.sh` and exercise the port handling around the relaunch path with a stubbed `start_app` (or a stubbed control server) so it needs no Electron, no display and no device, and runs in under a second.
- The specific assertions depend on the shape the fix takes and are listed as requirements in the Unit Tests section below.
- Add `"test:smoke-lib": "./smoke-tests/lib/common.test.sh"` to the `scripts` block of `apps/desktop/package.json`, alongside the existing `test:post-install` entry, and add `"test:desktop-smoke-lib": "cd ./apps/desktop && ./smoke-tests/lib/common.test.sh"` to the root `package.json`. Do not wire it into `test:everything` or `change-gate.json` in this plan.
- The test must pass before this step is complete.

### 10. Prove the fix with 100 consecutive green runs

- Run the existing fixed runner: `RUNS=100 mise exec -- scripts/check-flaky-tests.sh bun run test:electron -- 8`. Do not modify `scripts/check-flaky-tests.sh`.
- It bombs out at the first failing run, so a clean finish means 100 green runs. Capture its `LOG=<path>` output line.
- Because the production failure needed the relaunch path and a plain 100x of test 8 will almost certainly never take it, also run `RUNS=100` over the deterministic reproduction from step 3, converted for this purpose into a pass/fail check: the harness must exit 0 only when the command sent after `wait_for_ready` succeeds. That is the run that actually exercises the fixed path 100 times.
- Also run `RUNS=100 mise exec -- scripts/check-flaky-tests.sh bun run test:electron -- 7 8` if the fix touched test 7, so both share tests are covered.
- Copy the final summary of each 100x run into `docs/investigations/electron-8-share-database-flake/hundred-run-proof.log` and reference it from the README's `Fix and proof` section.
- **If any run in any of the 100x loops fails**: revert the fix (`git checkout` is not permitted without an explicit instruction, so undo the edit with `Edit` back to the original text), record the failing run's log in the evidence directory under `failed-attempt-<n>.log`, write down in the README why the fix did not work, and return to step 2 with what that failure taught. Do not patch over the new failure; do not add retries; do not raise a timeout to make it pass.

### 11. Close out the registry entry

- Only once the 100x loops are all clean: tick the `Fixed` checkbox in the `docs/flaky-tests-registry.md` entry and record the commit hash in `Fix commit`, as the registry's own rules require.
- If the entry cannot be ticked because the loops were not clean, leave it unticked and say so in the report.

### 12. Remove the diagnostic harness or justify keeping it

- `apps/desktop/smoke-tests/lib/relaunch-repro.sh` was built to prove the cause. Decide one of two things and state which in the report: delete it, because the shell unit test from step 9 now covers the behaviour permanently; or keep it, and add a header comment saying why the unit test is not sufficient.
- Default to deleting it. A one-off diagnostic left lying around is code nobody maintains.

## Unit Tests

All in `apps/desktop/smoke-tests/lib/common.test.sh`, run by `bun run test:smoke-lib` from `apps/desktop`. They use stubs and a temp directory, never a real Electron app, so they run anywhere in under a second. Written against whatever shape the fix takes in step 8; each requirement below describes the behaviour to assert, not the implementation.

- After `start_app` succeeds, `APP_PORT` holds the port written to `<tmp_dir>/test-control.port` by that launch. Asserted with a stub launcher that writes a known port.
- After the relaunch path inside `wait_for_ready` runs, the value a caller uses for subsequent commands is the port of the instance that is actually alive, not the port of the instance that was killed. This is the regression test for the bug and must fail against the pre-fix `common.sh`.
- `wait_for_ready` returns 0 without relaunching when `/ready` answers on the first attempt, and `APP_PORT` is unchanged by that call.
- `wait_for_ready` exits non-zero when both launch attempts fail, so a wedged app can never fall through to a test's later assertions.
- `start_app` removes a stale `<tmp_dir>/test-control.port` before launching, so a relaunch reads the new launch's port rather than the previous one. Asserted by seeding a stale port file and checking the value picked up.
- `send_command` reports a non-zero result when the port it is given has nothing serving it. This is the call that produced the observed exit 52 and its failure signalling is part of the cascade.

Note on scope: these are the only new unit tests. Do not add tests for unrelated helpers in `common.sh` (`wait_for_log`, `wait_for_value`, `check_no_errors`, `kill_app_tree`) in this plan. They are not implicated and adding them is exactly the over-reach this plan forbids.

## Smoke Tests

No new smoke test is added. `apps/desktop/smoke-tests/8-share-database/test.sh` and `apps/desktop/smoke-tests/7-share-secret/test.sh` already cover the behaviour end to end; the failure is in the harness that drives them, and the proof that it is fixed is the 100x loop in step 10 rather than a new scenario.

The end-to-end checks that must pass:

- `bun run test:electron -- 8` passes standalone.
- `bun run test:electron -- 7 8` passes, covering both share tests in sequence, which is the order that ran in production when the failure appeared.
- `bun run test:electron` passes in full, in the default mixed parallel and sequential mode, so the fix is exercised under the load pattern that produced the original failure.
- `RUNS=100 scripts/check-flaky-tests.sh bun run test:electron -- 8` completes without bombing out.
- The deterministic relaunch reproduction, run 100 times, passes every time.

## Verify

Run everything from the repository root through `mise exec --`.

- `mise exec -- bun run compile` succeeds with no TypeScript errors. No TypeScript is expected to change, so this confirms nothing was disturbed.
- `mise exec -- bun run test` passes.
- `mise exec -- bun run test:smoke-lib` (from `apps/desktop`) passes, and the relaunch regression test in it fails when run against the pre-fix `common.sh`, proving it actually tests the bug.
- `mise exec -- bun run test:electron -- 8` passes.
- `mise exec -- bun run test:electron` passes in full.
- `RUNS=100 mise exec -- scripts/check-flaky-tests.sh bun run test:electron -- 8` exits 0.
- The 100x deterministic reproduction loop exits 0.
- `docs/investigations/electron-8-share-database-flake/` exists and contains `README.md`, `observed-failure.log`, `reproduction.log` and `hundred-run-proof.log`, and the README's `Root cause` section states one falsifiable cause with pointers into those files.
- `docs/flaky-tests-registry.md` has a new entry for this mode, with the `Fixed` box ticked and a real commit hash in `Fix commit`, or unticked with the reason stated.
- `git diff --stat` does not list `.githooks/pre-commit`, `scripts/install-hooks.sh`, `scripts/test-everything-parallel.sh` or `scripts/check-flaky-tests.sh`.
- `git diff --stat` lists no file under `apps/desktop/src/`, `packages/` or any other application source directory. If it does, the change over-reached and must be reduced.

## Notes

- **The distinction this plan turns on.** The wedge that stops an Electron instance reaching `/ready` is the trigger. The reason a triggered relaunch turns into a test failure is the root cause. `wait_for_ready` was built to recover from the wedge, and it does recover: the transcript shows the relaunched app healthy and answering. Something after that point throws the recovery away. That "something" is what to find and fix. Fixing the wedge instead would be a much larger change with a much weaker proof.
- **Why 100 runs of test 8 alone is not sufficient proof on its own.** The relaunch path fires rarely (once in the sample so far). A hundred ordinary runs of test 8 would very likely take the happy path a hundred times and prove nothing about the fixed code. That is why step 10 requires 100 runs of the deterministic reproduction as well: that is the loop that actually exercises the repaired path every time.
- **`send_command` signals failure with `return`, not `exit`.** Other helpers in `common.sh` (`wait_for_log`, `wait_for_value`, `check_no_errors`, `wait_for_ready`) deliberately `exit` so a failure is fatal, and their comments explain that returning caused false passes in the past. `send_command` is the odd one out, and that is why the observed failure produced a confusing cascade: the real error was the curl failure, and the reported error was a log timeout 120 seconds later. Changing that is tempting and is **out of scope** unless the evidence proves it is part of the cause. If it is not, note it in the report as an observation for a separate decision.
- **`.flaky-check/` is not in `.gitignore`.** `scripts/check-flaky-tests.sh` writes its captures there and its header comment claims the directory is gitignored, which is not currently true. Do not fix that as part of this plan. Note it in the report and copy only the curated summaries into `docs/investigations/`, so nothing large or transient lands in the repository by accident.
- **Evidence lives in the repository, not in the session.** The scratchpad copy of the original `bun run smoke` output will not survive. Step 1 exists to get the transcript into a tracked file before anything else happens, so the investigation cannot lose the one failure it has.
- **Tests 7 and 8 both carry `.sequential` markers**, so they run one at a time after the parallel batch rather than alongside it. Whatever load caused the wedge was therefore not simple in-suite parallelism from the Electron suite itself. Candidates worth recording, not chasing: leftover processes from the parallel batch, another suite running concurrently on the same machine, or xvfb server startup contention.
- **`PER_TEST_TIMEOUT` in `apps/desktop/smoke-tests.sh` is 300 seconds** and its comment says it must accommodate two `DEFAULT_WAIT_TIMEOUT` waits (120 each) plus the test's own actions. Two full waits plus a two-instance share test does not fit comfortably in 300 seconds. This is an observation, not a licence to change either number.
- **Reverting a failed attempt.** `CLAUDE.md` forbids `git checkout`, `git restore` and similar without an explicit instruction in the message being acted on. Step 10's revert must therefore be done by editing the file back to its original text, which is why step 8 requires the fix to be recorded as a diff in the evidence README first.
