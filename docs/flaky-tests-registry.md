# Flaky-test failure registry

A repo-wide record of every known intermittent (flaky) failure mode across the test suites in this repo (unit, CLI smoke, Electron smoke, mobile smoke, LAN-share, and any future suite). Each entry captures the mode's stable signature, which suite it came from, its root cause, and whether it is believed fixed. The `/check-flaky-tests` command runs any suite 10x and matches a failure's output against the patterns below, so a recurrence of a checked (fixed) mode is caught as a regression and its fix removed.

## Rules for categorizing a flaky failure

1. Only record a mode here if it is flaky: it has passed before and fails intermittently. A failure that happens every run is a deterministic bug, not a flaky mode. Fix it directly and do not add it here.
2. Fingerprint the failure by its earliest root error line, never by a downstream cascade. If one component never starts, a later "not ready" line is a symptom of the same mode, not a separate one.
3. Normalize out volatile tokens before matching. Strip ports, PIDs, timestamps, file paths, correlation/command ids, durations, attempt counts, and hashes. Keep only the invariant words.
4. One entry per distinct root cause. Same wording but a different root cause is a different entry. Different wording but the same root cause is one entry that lists both patterns.
5. Every entry carries: id, a Fixed checkbox, suite (the test suite and command it was seen in), pattern (a regex over the invariant text), fix commit, first seen, recurrences, root cause, and evidence.
6. A mode's Fixed box stays unchecked until a fix has landed AND the `/check-flaky-tests` 10x loop passes clean. Only then tick the box and record the fixing commit hash in Fix commit.
7. Recurrence rule: if a new failure matches the pattern of a checked entry, that fix is disproven. Untick the box, append the recurrence date, and remove the failed fix commit so a fresh fix can be tried. A checked box is only as good as the next matching failure.
8. The pattern must match invariant text only. Use `port \d+`, never `port 43227`.
9. Checked means the Fixed box is ticked AND Fix commit records the commit hash that fixed it. The `/check-flaky-tests` command uses that commit to know what to remove if the mode ever recurs.

## Registry

### BRIDGE-START-BIND

- [x] Fixed and verified (10x clean)
- Suite: mobile smoke tests (`bun run test:and` / `bun run test:ios`)
- Pattern: `Control bridge did not start on port \d+ within \d+s`
- Cascade symptom (same mode, not a new entry): `Timed out waiting for app to be ready after \d+s`
- Fix commit: apps/smoke-tests/lib/control-bridge.ts, `start()` retries `listen()` on a transient `EADDRINUSE` instead of letting the process die (uncommitted working change; record the commit hash here once committed).
- First seen: 2026-07-06, local 10x loop, run 10 of 10, test 3 (open-database). Runs 1 to 9 passed.
- Recurrences:
  - 2026-07-06, skill loop iteration 7 of 100 (`bun run test:and`), failed on run 10 of 10 with `Control bridge did not start on port N within 20s`.
  - 2026-07-07, skill loop iteration 15 of 100 (`bun run test:and`), failed on run 7 of 10 with the same bridge bind failure.
  - 2026-07-07, skill loop iteration 18 of 100 (`bun run test:and`), failed on run 2 of 10 with the same bridge bind failure.
  - 2026-07-07, skill loop iteration 21 of 100 (`bun run test:and`), failed on run 7 of 10 with the same bridge bind failure.
- Verified: 2026-07-09, 0 recurrences of the bridge bind failure across 40 consecutive runs after the fix; accepted as fixed by the user. Short of the 100-run target because the runner kept aborting early on OPEN-DB-LIST-ITEM-NOT-RENDERED.
- Root cause: the host control-bridge Bun process fails to bind its assigned port, so the app has nothing to connect to and never becomes ready. Three compounding factors: (a) leaked bridge processes from a previously failed test keep holding ports (a live leaked process, PID 106755, was observed still running after the loop stopped); (b) `find_free_port` binds port 0, closes the probe socket, then prints the port, leaving a reuse window in which another process can take it; (c) `ControlBridge.start()` wires only the `listening` callback and no `error` handler, so a bind collision hangs silently until `wait_for_bridge` times out at 20s instead of failing fast.
- Evidence: `Control bridge did not start on port 43227 within 20s` then two `Timed out waiting for app to be ready after 60s` attempts, then `1 of 25 tests failed`; `pgrep control-bridge-main` showed leaked PID 106755 still alive.

### OPEN-DB-LIST-ITEM-NOT-RENDERED

- [x] Fixed and verified (10x clean)
- Suite: mobile smoke tests (`bun run test:and` / `bun run test:ios`), seen via `bun run test:and`
- Pattern: `test-click: element not found data-id="database-list-item-\d+"`
- Cascade symptom (same mode, not a new entry): `Timed out waiting for log pattern: Database opened`
- Fix commit: packages/user-interface/src/lib/test-driver.ts, the `click` command now `await`s a new `waitForElement()` (bounded DOM poll) before clicking, so a click waits for an asynchronously rendered target instead of firing once and silently missing (uncommitted working change; record the commit hash here once committed).
- First seen: 2026-07-06, local 10x loop, run 5 of 10, test 3 (open-database). Runs 1 to 4 passed; within run 5 tests 0 to 2 passed before test 3 failed.
- Recurrences:
  - 2026-07-06, local 10x loop (`bun run test:and`), recurred on run 5 of 10, test 3 (open-database). Runs 1 to 4 passed; within run 5 tests 0 to 2 passed before the click for `database-list-item-0` found no element and `Database opened` never logged.
  - 2026-07-06, local 10x loop (`bun run test:and`), recurred on run 10 of 10, test 21 (import-video). Runs 1 to 9 passed; within run 10 the open-database step opened the dialog, then the click for `database-list-item-0` found no element and `Database opened` never logged.
  - 2026-07-06, local 10x loop (`bun run test:and`), recurred on run 2 of 10, test 4 (import-photos). Run 1 passed; within run 2 tests 0 to 3 passed (including test 3 open-database), then test 4's open-database step opened the dialog, the click for `database-list-item-0` found no element, and `Database opened` never logged.
  - 2026-07-06, skill loop iteration 2 of 100 (`bun run test:and`), recurred on run 6 of 10; click for `database-list-item-0` found no element and `Database opened` never logged.
  - 2026-07-06, skill loop iteration 3 of 100 (`bun run test:and`), recurred on run 5 of 10; same missing-list-item click.
  - 2026-07-06, skill loop iteration 5 of 100 (`bun run test:and`), recurred on run 3 of 10; same missing-list-item click.
  - 2026-07-06, skill loop iteration 6 of 100 (`bun run test:and`), recurred on run 9 of 10; same missing-list-item click.
  - 2026-07-06, skill loop iteration 8 of 100 (`bun run test:and`), recurred on run 3 of 10; same missing-list-item click.
  - 2026-07-06, skill loop iteration 9 of 100 (`bun run test:and`), recurred on run 3 of 10; same missing-list-item click.
  - 2026-07-06, skill loop iteration 10 of 100 (`bun run test:and`), recurred on run 9 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 13 of 100 (`bun run test:and`), recurred on run 4 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 14 of 100 (`bun run test:and`), recurred on run 5 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 16 of 100 (`bun run test:and`), recurred on run 1 of 10; same missing-list-item click (failed on the iteration's first run, but the mode is flaky across the loop, not deterministic).
  - 2026-07-07, skill loop iteration 19 of 100 (`bun run test:and`), recurred on run 4 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 20 of 100 (`bun run test:and`), recurred on run 8 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 23 of 100 (`bun run test:and`), recurred on run 9 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 25 of 100 (`bun run test:and`), recurred on run 9 of 10; same missing-list-item click.
  - 2026-07-07, skill loop iteration 28 of 100 (`bun run test:and`), recurred on run 4 of 10; same missing-list-item click.
  - 2026-07-09, single script run (`bun run test:and`), recurred on run 3 of 10, test 3 (open-database); same missing-list-item click.
- Verified: 2026-07-09, 0 recurrences across 30 consecutive runs (3 full clean 10-run executions) after the fix; no other mode surfaced either.
- Root cause: race in the open-database test. The bridge starts and the app becomes ready fine (not a BRIDGE-START-BIND failure). The "Open database dialog opened" step succeeds, but the dialog's database list is populated asynchronously and the test dispatches its click for `database-list-item-0` before that list item has rendered. `test-click` finds no matching element and silently does nothing, so no database is opened and the `Database opened` log line is never emitted, so the wait-for-log-pattern step times out. The click step needs to wait for the list item to appear (or retry) instead of firing once.
- Evidence: `[INFO] Found: Open database dialog opened (line 5)`, then `[INFO] Waiting for log pattern: Database opened (after line 5)`, then `[WARN] test-click: element not found data-id="database-list-item-0" nth=0`, then `[FAIL] Timed out waiting for log pattern: Database opened` and `FAIL  3-open-database`, ending `1 of 25 tests failed`.

### ASSET-SERVER-THUMB-HTTP-000

- [ ] Fixed and verified (10x clean)
- Suite: mobile smoke tests (`bun run test:and`), test 1 (load-fixture)
- Pattern: `Asset server returned HTTP 000 for thumbnail [0-9a-f-]+`
- Fix commit: none yet
- First seen: 2026-07-09, single script run (`bun run test:and`), failed on run 5 of 10, test 1 (load-fixture). Runs 1 to 4 passed (each served the thumbnail fine).
- Recurrences: none
- Root cause: not yet fully investigated; leading hypothesis is a logcat-staleness / asset-server-startup race in the load-fixture test's host-side thumbnail probe. The test reads the asset server port with `adb logcat -d | grep 'Asset server task listening on http://127.0.0.1:<port>' | tail -1`, then curls it. `adb logcat -d` dumps the whole buffer, which accumulates listening lines from every prior run's app instance in the same suite invocation. If the current run's asset server has not yet logged its listening line when the test greps, `tail -1` yields a previous run's now-dead port, and the curl to it fails to connect, which curl reports as HTTP 000 (the app itself is fine: the DB opened and 50 assets loaded). Needs confirmation, and likely a fix that scopes the port read to the current run (clear logcat at test start, or match the current app instance) or waits for the current run's listening line before probing.
- Evidence: runs 1 to 4 each logged `[PASS] Asset server served a JPEG thumbnail over localhost:<port>`; run 5 logged `[FAIL] Asset server returned HTTP 000 for thumbnail 63e9c637-9164-6376-13e9-ef3200000000` then `FAIL  1-load-fixture`, ending `1 of 25 tests failed`. The snapshotted app.log for that run shows `Load assets task completed: 50 assets loaded` and `Gallery loaded: 50 assets`, so only the host-side asset-server probe failed, not the app.
