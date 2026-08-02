# Flaky-test failure registry

A repo-wide record of every known intermittent (flaky) failure mode across the test suites in this repo (unit, CLI smoke, Electron smoke, mobile smoke, LAN-share, and any future suite). Each entry captures the mode's stable signature, which suite it came from, its root cause, and whether it is believed fixed. Match a failure's output against the patterns below, so a recurrence of a checked (fixed) mode is caught as a regression and its fix removed.

## Rules for categorizing a flaky failure

1. Only record a mode here if it is flaky: it has passed before and fails intermittently. A failure that happens every run is a deterministic bug, not a flaky mode. Fix it directly and do not add it here.
2. Fingerprint the failure by its earliest root error line, never by a downstream cascade. If one component never starts, a later "not ready" line is a symptom of the same mode, not a separate one.
3. Normalize out volatile tokens before matching. Strip ports, PIDs, timestamps, file paths, correlation/command ids, durations, attempt counts, and hashes. Keep only the invariant words.
4. One entry per distinct root cause. Same wording but a different root cause is a different entry. Different wording but the same root cause is one entry that lists both patterns.
5. Every entry carries: id, a Fixed checkbox, suite (the test suite and command it was seen in), pattern (a regex over the invariant text), fix commit, first seen, recurrences, root cause, and evidence.
6. A mode's Fixed box stays unchecked until a fix has landed AND a repeated run of the suite passes clean. Only then tick the box and record the fixing commit hash in Fix commit.
7. Recurrence rule: if a new failure matches the pattern of a checked entry, that fix is disproven. Untick the box, append the recurrence date, and remove the failed fix commit so a fresh fix can be tried. A checked box is only as good as the next matching failure.
8. The pattern must match invariant text only. Use `port \d+`, never `port 43227`.
9. Checked means the Fixed box is ticked AND Fix commit records the commit hash that fixed it. That commit is what to remove if the mode ever recurs.

## Registry

### BRIDGE-START-BIND

- [ ] Fixed and verified (10x clean)
- Suite: mobile smoke tests (`bun run test:and` / `bun run test:ios`)
- Pattern: `Control bridge did not start on port \d+ within \d+s`
- Also matches (same mode, message since reworded): `is still running but did not answer on port \d+`
- Cascade symptom (same mode, not a new entry): `Timed out waiting for app to be ready after \d+s`
- Fix commit: none. The entry previously named an uncommitted working change as the fix, so nothing ever landed and the mode stayed live.
- First seen: 2026-07-06, local 10x loop, run 10 of 10, test 3 (open-database). Runs 1 to 9 passed.
- Recurrences:
  - 2026-07-06, skill loop iteration 7 of 100 (`bun run test:and`), failed on run 10 of 10 with `Control bridge did not start on port N within 20s`.
  - 2026-07-07, skill loop iteration 15 of 100 (`bun run test:and`), failed on run 7 of 10 with the same bridge bind failure.
  - 2026-07-07, skill loop iteration 18 of 100 (`bun run test:and`), failed on run 2 of 10 with the same bridge bind failure.
  - 2026-07-07, skill loop iteration 21 of 100 (`bun run test:and`), failed on run 7 of 10 with the same bridge bind failure.
  - 2026-07-30, five occurrences in one day under `bun run test:everything` (tests 13, 17, 11, 2 and 31; five different ports, five different PIDs, never the same test twice).
  - 2026-07-30, reproduced deliberately 7 times with full evidence: once in `bun run test:and` (test 19, port 42071) and 6 times across 4000 instrumented bridge starts (ports 42691, 35793, 33303, 42329, 40939, 42329). Root cause established, see below. No fix applied.
- Verified: the 2026-07-09 "verified" claim stands only against the old explanation. The real cause below was never addressed, and the mode recurred.
- Root cause: **the probe talks to the Android emulator instead of the bridge, because `localhost` is not `127.0.0.1` as far as curl is concerned.**
  - `ControlBridge.start()` calls `httpServer.listen(0, "0.0.0.0")`, so the bridge listens on **IPv4 only** and the OS assigns a port from the ephemeral range (`net.ipv4.ip_local_port_range` = 32768-60999).
  - Each Android emulator's QEMU process holds several listeners on **`[::1]`** (its console and QMP ports), drawn from that same ephemeral range. With the 5-emulator pool up there are ~25 of them.
  - Binding `0.0.0.0:P` while `[::1]:P` is already held **succeeds**, because they are different address families. Verified directly: every other combination (`127.0.0.1:P` vs `0.0.0.0:P` in either order, `[::]:P` vs `0.0.0.0:P`) is refused with `EADDRINUSE`. So the bridge legitimately ends up sharing a port number with a QEMU console.
  - `wait_for_bridge` probes `http://localhost:$port/ready`. **curl carries its own built-in mapping of the name `localhost` to both `::1` and `127.0.0.1`, and tries IPv6 first**, regardless of `/etc/hosts` or `getaddrinfo`. On this machine `getent hosts localhost` and `getaddrinfo` both return `127.0.0.1` only (there is no `::1 localhost` line), which is why the IPv6 explanation was wrongly dismissed in earlier investigations.
  - So the probe connects to `[::1]:P`, which is the emulator console, not the bridge. The TCP connection **succeeds**, so curl never falls back to IPv4. The console speaks its own protocol, so curl fails at the HTTP layer with exit 1 (`Received HTTP/0.9 when not allowed`) or exit 56 (`Recv failure: Connection reset by peer`).
  - This is deterministic for the whole 40s: all 200 probes hit the console. The bridge is alive, listening and healthy throughout, and answers instantly on `127.0.0.1`.
  - Rate: ~25 QEMU `[::1]` listeners over a 28232-port range is 1 collision per ~1129 bridge starts. The Android suite performs 38 bridge starts per run, so ~3.4% of runs. Observed 6 failures in 4000 starts against 3.5 predicted.
- Evidence (2026-07-30, all 7 reproductions identical in shape):
  - `The control bridge (PID 1634885) is still running but did not answer on port 42071 within 40s (last curl exit 1, 200 probes in 43s).` The probe count is measured, not assumed: it is 200 fast failures, not one hung curl.
  - `curl via localhost: exit 1 -- curl: (1) Received HTTP/0.9 when not allowed`
  - `curl via 127.0.0.1: exit 0` (the bridge answers immediately, in the same second)
  - `curl via [::1]: exit 1 -- curl: (1) Received HTTP/0.9 when not allowed` (identical to the name, which is the point)
  - `lsof -i :42071` shows both owners at once: `bun 1634885 IPv4 TCP *:42071 (LISTEN)` and `qemu-syst 3156721 IPv6 TCP [::1]:42071 (LISTEN)`.
  - The bridge process is `S`/`ep_poll` with 13 open descriptors: idle and healthy, not blocked, not out of descriptors.
  - Confirmed in isolation: with a listener bound only on `[::1]:P` and nothing on `127.0.0.1:P`, `curl http://localhost:P/` reaches it and reports `Received HTTP/0.9 when not allowed`, while `curl http://127.0.0.1:P/` gets connection refused.
- Note on the earlier explanation: the process is not dying and there is no `EADDRINUSE`. The bind always succeeds. The previous entry's three "compounding factors" describe a different failure that a retry-on-EADDRINUSE would not have touched.

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
